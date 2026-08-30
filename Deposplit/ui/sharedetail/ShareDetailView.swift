import hexagon
import SwiftUI

struct ShareDetailView: View {
    @State private var viewModel: ShareDetailViewModel

    init(target: ShareDetailTarget, shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        _viewModel = State(initialValue: ShareDetailViewModel(
            target: target, shareManagement: shareManagement, contactManagement: contactManagement))
    }

    var body: some View {
        List {
            Section("Share") {
                LabeledContent("Label", value: viewModel.shareLabel)
                LabeledContent("Recipient", value: viewModel.recipientName)
            }

            Section("Requests") {
                RequestRow(label: "Retrieval",
                           state: viewModel.requestState(for: .retrieval),
                           isActing: viewModel.isActing) {
                    Task { await viewModel.openRequest(type: .retrieval) }
                }
                RequestRow(label: "Removal",
                           state: viewModel.requestState(for: .removal),
                           isActing: viewModel.isActing) {
                    Task { await viewModel.openRequest(type: .removal) }
                }
            }

            Section("Reconstruct") {
                switch viewModel.reconstructState {
                case .unavailable(let reason):
                    Text(reason).foregroundStyle(.secondary).font(.caption)
                case .ready:
                    BiometricGatedButton(
                        label: "Reconstruct secret…",
                        reason: String(localized: "Authenticate to reconstruct your secret")
                    ) {
                        _ = await viewModel.reconstruct()
                    }
                case .reconstructed(let secret, let integrity):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(secret)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = secret
                        }
                        .font(.caption)
                        ReconstructionAdvisoryView(integrity: integrity, contactName: viewModel.contactName)
                    }
                case .failed(let msg):
                    Text("Error: \(msg)").foregroundStyle(.red).font(.caption)
                }
            }

            if let error = viewModel.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(viewModel.shareLabel)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if viewModel.isLoading { ProgressView() }
        }
        .task { await viewModel.load() }
    }
}

private struct RequestRow: View {
    let label: LocalizedStringKey
    let state: ShareRequestState?
    let isActing: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if let state {
                Text(state.label)
                    .font(.caption)
                    .foregroundStyle(stateColor(state))
                if state == .denied {
                    Button("Re-open", action: action)
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .disabled(isActing)
                }
            } else {
                Button("Open request", action: action)
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .disabled(isActing)
            }
        }
    }

    private func stateColor(_ state: ShareRequestState) -> Color {
        switch state {
        case .pending: .orange
        case .approved: .green
        case .denied: .red
        // Deposit-only — a syncDistributed() poll removes the local pointer for a
        // withdrawn deposit as soon as it's observed, so this rarely reaches the UI in practice.
        case .withdrawn: .gray
        }
    }
}

private extension ShareRequestState {
    var label: LocalizedStringKey {
        switch self {
        case .pending: "Pending"
        case .approved: "Approved"
        case .denied: "Denied"
        case .withdrawn: "Withdrawn"
        }
    }
}

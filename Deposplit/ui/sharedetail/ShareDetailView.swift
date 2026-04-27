import SwiftUI

struct ShareDetailView: View {
    @State private var viewModel: ShareDetailViewModel
    @State private var reconstructedSecret: String?
    @State private var showLocalAuth = false

    init(share: ShareMetadata, auth: AuthPort, transport: ShareTransport, contacts: ContactRepository) {
        _viewModel = State(initialValue: ShareDetailViewModel(
            share: share, auth: auth, transport: transport, contacts: contacts))
    }

    var body: some View {
        List {
            Section("Share") {
                LabeledContent("Label", value: viewModel.shareLabel)
                LabeledContent("Recipient", value: viewModel.recipientName)
            }

            Section("Requests") {
                RequestRow(label: "Retrieve",
                           state: viewModel.requestState(for: .retrieve),
                           isActing: viewModel.isActing) {
                    Task { await viewModel.openRequest(type: .retrieve) }
                }
                RequestRow(label: "Delete",
                           state: viewModel.requestState(for: .delete),
                           isActing: viewModel.isActing) {
                    Task { await viewModel.openRequest(type: .delete) }
                }
            }

            Section("Reconstruct") {
                switch viewModel.reconstructState {
                case .unavailable(let reason):
                    Text(reason).foregroundStyle(.secondary).font(.caption)
                case .ready:
                    Button("Reconstruct secret…") {
                        Task {
                            reconstructedSecret = await viewModel.reconstruct()
                        }
                    }
                case .reconstructed(let secret):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(secret)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = secret
                        }
                        .font(.caption)
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
                Text(state.localizedLabel)
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
        }
    }
}

import hexagon
import SwiftUI

/// The one-tap-ish repair flow: gather k approved retrievals → reconstruct → re-deposit
/// (prefilled) → optionally discard the old distribution. A single screen with internal wizard
/// state (`RepairViewModel.Phase`), not a chain of nav-graph destinations, so the reconstructed
/// plaintext never leaves this one ViewModel's memory or gets serialized into a navigation route.
struct RepairView: View {
    @State private var viewModel: RepairViewModel
    @Environment(\.dismiss) private var dismiss
    let onFinished: () -> Void

    init(secret: Secret, shareManagement: any ShareManagement, contactManagement: any ContactManagement, onFinished: @escaping () -> Void) {
        _viewModel = State(initialValue: RepairViewModel(secret: secret, shareManagement: shareManagement, contactManagement: contactManagement))
        self.onFinished = onFinished
    }

    var body: some View {
        NavigationStack {
            switch viewModel.phase {
            case .gathering, .reconstructing:
                gatheringContent
                    .navigationTitle("Repair \(viewModel.secret.label)")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
            case .redeposit:
                if let depositViewModel = viewModel.depositViewModel {
                    VStack(spacing: 0) {
                        if let integrity = viewModel.reconstructionIntegrity {
                            ReconstructionAdvisoryView(integrity: integrity, contactName: viewModel.contactName)
                                .padding()
                        }
                        DepositFormContent(viewModel: depositViewModel, title: "Repair — Re-deposit") {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { dismiss() }
                            }
                        }
                    }
                    .onChange(of: depositViewModel.depositedSuccessfully) { _, success in
                        if success { viewModel.newDepositSucceeded() }
                    }
                }
            case .confirmDiscard:
                confirmDiscardContent
                    .navigationTitle("Repair \(viewModel.secret.label)")
                    .navigationBarTitleDisplayMode(.inline)
            case .done:
                doneContent
                    .navigationTitle("Repair \(viewModel.secret.label)")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await viewModel.load() }
    }

    private var gatheringContent: some View {
        List {
            Section {
                Text("Need \(viewModel.secret.k) approved retrieval(s) to reconstruct — \(viewModel.approvedCount) so far.")
                    .font(.subheadline)
            }
            Section("Holders") {
                if viewModel.holderStatuses.isEmpty {
                    Text("No holders on record for this secret.").foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.holderStatuses) { holder in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(holder.pseudonym)
                                if let subtitle = holder.subtitle {
                                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(holder.requestState?.label ?? "Not requested")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button {
                    Task { await viewModel.requestMissingRetrievals() }
                } label: {
                    if viewModel.isActing { ProgressView() } else { Text("Request Missing Retrievals") }
                }
                .disabled(viewModel.isActing)

                if viewModel.readyToReconstruct {
                    BiometricGatedButton(
                        label: "Reconstruct",
                        reason: String(localized: "Authenticate to reconstruct your secret"),
                        isDisabled: viewModel.isActing
                    ) {
                        await viewModel.reconstruct()
                    }
                }
            }
            if let error = viewModel.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .overlay {
            if viewModel.isLoading || viewModel.phase == .reconstructing { ProgressView() }
        }
    }

    private var confirmDiscardContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle").font(.system(size: 44)).foregroundStyle(.green)
            Text("Repair complete").font(.headline)
            Text("Deposited to \(viewModel.depositedHolderCount) new holder(s). Discard the old distribution now? Each of its holders will be asked to delete their copy.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Discard Old Distribution", role: .destructive) {
                Task { await viewModel.discardOldAndFinish() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isActing)
            Button("Not Now") { viewModel.skipDiscard() }
            Spacer()
        }
        .padding()
    }

    private var doneContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text("Done").font(.headline)
            Button("Close") {
                onFinished()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
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

import hexagon
import SwiftUI

/// One secret: who holds a piece of it, and the three things that can be done to the whole of it.
///
/// All three controls stay put whatever the state — what changes is whether they are enabled and
/// the line underneath saying why not. A control that vanishes leaves the reader hunting for
/// something they remember seeing, and teaches nothing about what k means.
struct SecretDetailView: View {
    let secretId: UUID
    let shareManagement: any ShareManagement
    let contactManagement: any ContactManagement
    let onTapHolder: (ShareDetailTarget) -> Void
    let onRepair: (Secret) -> Void

    @State private var viewModel: SecretDetailViewModel
    @State private var confirmingClear = false
    @State private var confirmingDiscard = false
    @Environment(\.dismiss) private var dismiss

    init(
        secretId: UUID,
        shareManagement: any ShareManagement,
        contactManagement: any ContactManagement,
        onTapHolder: @escaping (ShareDetailTarget) -> Void,
        onRepair: @escaping (Secret) -> Void
    ) {
        self.secretId = secretId
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
        self.onTapHolder = onTapHolder
        self.onRepair = onRepair
        _viewModel = State(initialValue: SecretDetailViewModel(
            secretId: secretId,
            shareManagement: shareManagement,
            contactManagement: contactManagement
        ))
    }

    var body: some View {
        Group {
            if let group = viewModel.group {
                List {
                    Section {
                        Text("\(group.secret.k) of \(group.secret.n) needed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        healthBadge(group)
                    }

                    Section("Holders") {
                        ForEach(group.holders) { holder in
                            Button {
                                onTapHolder(ShareDetailTarget(
                                    secret: group.secret,
                                    share: ShareMetadata(
                                        id: holder.shareId,
                                        secretId: group.secret.id,
                                        contactId: holder.contactId
                                    )
                                ))
                            } label: {
                                holderRow(holder)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    actionsSection(group)

                    if let reconstructed = viewModel.reconstructed {
                        Section {
                            ReconstructedSecretView(
                                secret: reconstructed.secret,
                                mimeType: viewModel.mimeType,
                                label: viewModel.label
                            )
                            ReconstructionAdvisoryView(
                                integrity: reconstructed.integrity,
                                contactName: viewModel.contactName
                            )
                        }
                    }

                    if let actionError = viewModel.actionError {
                        Section { Text(actionError).foregroundStyle(.red).font(.caption) }
                    }

                    Section {
                        if group.health == .caution || group.health == .critical {
                            Button("Repair") { onRepair(group.secret) }
                                .tint(group.health == .critical ? .orange : nil)
                        }
                        if group.secret.state == .discarding {
                            Text("Discarding…").font(.caption).foregroundStyle(.orange)
                            Button("Force Forget", role: .destructive) {
                                Task {
                                    await viewModel.forceForget()
                                    dismiss()
                                }
                            }
                        } else {
                            Button("Discard", role: .destructive) { confirmingDiscard = true }
                        }
                    }
                }
            } else if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(viewModel.error ?? String(localized: "Failed to load"))
                )
            }
        }
        .navigationTitle(viewModel.label)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        // Two texts, neither claiming anything about what the reader remembers: all that is known
        // is whether the secret is on this screen right now.
        .confirmationDialog(
            "Clear collected copies?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear collected copies", role: .destructive) {
                Task { await viewModel.clearCollected() }
            }
        } message: {
            if viewModel.hasBeenShown {
                Text("The holders keep their pieces — copies can be asked for again at any time.")
            } else {
                Text("The secret has not been shown here. Clearing the collected copies means asking the holders again before it can be put back together.")
            }
        }
        .confirmationDialog(
            "Discard this secret?",
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                Task { await viewModel.discard() }
            }
        } message: {
            Text("Requests deletion from all \(viewModel.group?.holders.count ?? 0) holder(s). Each must approve — this only removes it from your device's list once every holder confirms (or you force-forget it).")
        }
    }

    /// The three secret-level actions, each with the reason it cannot be pressed set out beneath.
    @ViewBuilder
    private func actionsSection(_ group: SecretGroup) -> some View {
        Section {
            Button("Request Retrieval (all)") { Task { await viewModel.requestAll() } }
                .disabled(!group.canRequestRetrieval || viewModel.busy)
            BiometricGatedButton(
                label: "Reconstruct secret…",
                reason: String(localized: "Authenticate to reconstruct your secret"),
                isDisabled: !group.canReconstruct || viewModel.busy
            ) {
                await viewModel.reconstruct()
            }
            Button("Clear collected copies") { confirmingClear = true }
                .disabled(!group.canClearCollected || viewModel.busy)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(group.approvedRetrievals) of the \(group.secret.k) needed have handed their piece back")
                if let reason = group.retrievalUnavailableReason {
                    Text(reason)
                }
                if group.reconstructShortfall > 0 {
                    Text("\(group.reconstructShortfall) more holder(s) have to hand a piece back first.")
                }
                if !group.canClearCollected {
                    Text("Nothing has been handed back yet.")
                }
                // Standing advice rather than a dialog over the secret: the moment it is finally on
                // screen is the worst possible moment to cover it with something that asks for
                // nothing.
                if viewModel.hasBeenShown && group.canClearCollected {
                    Text("Clear the collected copies once you are done with the secret — the holders keep their pieces either way.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func holderRow(_ holder: HolderStatus) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.contactName(holder.contactId))
                if let subtitle = viewModel.contactSubtitle(holder.contactId) {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                // Early nudge, surfaced before the holder actually drops out of n_live.
                if holder.isGettingStale {
                    Label("Getting stale", systemImage: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                } else if holder.freshnessBucket == .unmonitored {
                    Label("Unmonitored by choice", systemImage: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if holder.freshnessBucket == .silentOverdue {
                    Label("Silent — possible loss", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if let state = holder.retrievalRequest?.state {
                Text(state.detailLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func healthBadge(_ group: SecretGroup) -> some View {
        switch group.health {
        case .discarding:
            Label("Discarding", systemImage: "trash").font(.caption2).foregroundStyle(.orange)
        case .healthy:
            EmptyView()
        case .caution:
            Label("Margin of one — re-split soon", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.yellow)
        case .critical:
            Label("Reconstruct + re-split now", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
        case .lost:
            Label("Unrecoverable", systemImage: "xmark.octagon.fill").font(.caption2).foregroundStyle(.red)
        }
    }
}

private extension ShareRequestState {
    var detailLabel: LocalizedStringKey {
        switch self {
        case .pending: "Pending"
        case .approved: "Approved"
        case .denied: "Denied"
        case .withdrawn: "Withdrawn"
        }
    }
}

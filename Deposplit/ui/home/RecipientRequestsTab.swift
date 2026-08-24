import hexagon
import SwiftUI

struct RecipientRequestsTab: View {
    @Bindable var viewModel: RequestsViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .imageScale(.small)
                    Text(error)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry") { Task { await viewModel.load() } }
                        .font(.caption)
                }
                .foregroundStyle(.red)
                .padding(.horizontal)
                .padding(.vertical, 6)
                Divider()
            }
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.error != nil && viewModel.pendingRequests.isEmpty && viewModel.keyConflicts.isEmpty {
                Spacer()
            } else if viewModel.pendingRequests.isEmpty && viewModel.keyConflicts.isEmpty {
                ContentUnavailableView("No pending requests", systemImage: "checkmark.circle")
            } else {
                List {
                    if !viewModel.keyConflicts.isEmpty {
                        Section("Key Conflicts") {
                            ForEach(viewModel.keyConflicts) { conflict in
                                KeyConflictCard(
                                    conflict: conflict,
                                    contactName: viewModel.contactName(for: conflict),
                                    onDismiss: { viewModel.dismissConflict(conflict) }
                                )
                            }
                        }
                    }
                    if !viewModel.pendingRequests.isEmpty {
                        Section(viewModel.keyConflicts.isEmpty ? "" : "Pending Requests") {
                            ForEach(viewModel.pendingRequests) { request in
                                RequestCard(
                                    request: request,
                                    senderName: viewModel.senderName(for: request),
                                    senderSubtitle: viewModel.senderSubtitle(for: request),
                                    keyChangedDaysAgo: viewModel.keyChangedDaysAgo(for: request),
                                    isResponding: viewModel.respondingTo == request.id,
                                    onApprove: { Task { await viewModel.respond(to: request, approve: true) } },
                                    onDeny: { Task { await viewModel.respond(to: request, approve: false) } }
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct RequestCard: View {
    let request: ShareRequest
    let senderName: String
    // Item 15 — the sender's pseudonym, shown only when senderName above is actually a nickname.
    let senderSubtitle: String?
    let keyChangedDaysAgo: Int?
    let isResponding: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(request.label).font(.headline)
                Spacer()
                Text(request.transactionType.label)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(badgeColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            Text("From: \(senderName)").font(.caption).foregroundStyle(.secondary)
            if let subtitle = senderSubtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            // Item 10's retrieve-approval hardening — the attack signature is key change
            // followed by a quick retrieval request, so nudge toward a fresh out-of-band check.
            if let days = keyChangedDaysAgo {
                Label("\(senderName)'s key changed \(days) days ago — verify fresh before approving", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                if isResponding {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Button("Deny", role: .destructive, action: onDeny)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    Button("Approve", action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var badgeColor: Color {
        request.transactionType == .retrieval ? .blue : .orange
    }
}

/// Item 10 — never auto-resolved. Resolving "yes, this really was them" goes through the
/// existing Relink flow (a fresh human-verified re-scan) on the Contacts screen, not through
/// anything here; this card only warns and lets the user acknowledge (dismiss) the alert.
private struct KeyConflictCard: View {
    let conflict: KeyConflict
    let contactName: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Possible impersonation attempt", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("\(contactName)'s key changed, but their previous key is flagged compromised. This could be an attacker with the stolen key, or a false alarm. To reconnect, verify \(contactName) fresh — in person or over a trusted channel — then use Relink from the Contacts screen. Do not accept this automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Detected \(conflict.detectedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
    }
}

private extension ShareTransactionType {
    var label: LocalizedStringKey {
        switch self {
        case .deposit: "Deposit"
        case .retrieval: "Retrieval"
        case .removal: "Removal"
        // Never surfaced here — inventory is a self-approved push, consumed silently by
        // syncInbox's processRecoveryMetadata, not routed through listPendingRequests.
        case .inventory: "Inventory"
        }
    }
}

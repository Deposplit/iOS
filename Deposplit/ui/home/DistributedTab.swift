import hexagon
import SwiftUI

struct ShareDetailTarget: Identifiable, Hashable {
    let secret: Secret
    let share: ShareMetadata
    static func == (lhs: ShareDetailTarget, rhs: ShareDetailTarget) -> Bool { lhs.share.id == rhs.share.id }
    func hash(into hasher: inout Hasher) { hasher.combine(share.id) }
    var id: UUID { share.id }
}

struct DistributedTab: View {
    let groups: [SecretGroup]
    let contacts: [Contact]
    let requestingAllIds: Set<UUID>
    let onTapHolder: (ShareDetailTarget) -> Void
    let onRequestAll: (UUID) -> Void
    let onDiscard: (UUID) -> Void
    let onForceForget: (UUID) -> Void

    @State private var expandedSecretId: UUID?
    @State private var pendingDiscard: SecretGroup?

    var body: some View {
        VStack(spacing: 0) {
            if groups.isEmpty {
                ContentUnavailableView("No distributed shares", systemImage: "lock.open")
            } else {
                List {
                    ForEach(groups) { group in
                        SecretGroupRow(
                            group: group,
                            isExpanded: expandedSecretId == group.id,
                            isRequestingAll: requestingAllIds.contains(group.id),
                            contactName: { contactId in contactName(for: contactId) },
                            onToggle: {
                                expandedSecretId = expandedSecretId == group.id ? nil : group.id
                            },
                            onHolderTap: { holder in
                                onTapHolder(ShareDetailTarget(secret: group.secret, share: ShareMetadata(id: holder.shareId, secretId: group.secret.id, contactId: holder.contactId)))
                            },
                            onRequestAll: { onRequestAll(group.id) },
                            onDiscard: { pendingDiscard = group },
                            onForceForget: { onForceForget(group.id) }
                        )
                    }
                }
            }
        }
        .confirmationDialog(
            "Discard this secret?",
            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
            presenting: pendingDiscard
        ) { group in
            Button("Discard \(group.secret.label)", role: .destructive) {
                onDiscard(group.id)
                pendingDiscard = nil
            }
        } message: { group in
            Text("Requests deletion from all \(group.holders.count) holder(s). Each must approve — this only removes it from your device's list once every holder confirms (or you force-forget it).")
        }
    }

    private func contactName(for contactId: UUID) -> String {
        contacts.first(where: { $0.id == contactId })?.pseudonym ?? String(localized: "Unknown contact")
    }
}

private struct SecretGroupRow: View {
    let group: SecretGroup
    let isExpanded: Bool
    let isRequestingAll: Bool
    let contactName: (UUID) -> String
    let onToggle: () -> Void
    let onHolderTap: (HolderStatus) -> Void
    let onRequestAll: () -> Void
    let onDiscard: () -> Void
    let onForceForget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggle) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.secret.label).font(.headline)
                        HStack(spacing: 6) {
                            Text(group.secret.secretCreatedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            healthBadge
                        }
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(group.holders) { holder in
                    Button {
                        onHolderTap(holder)
                    } label: {
                        HStack {
                            Text(contactName(holder.contactId))
                            Spacer()
                            if let state = holder.retrieveRequest?.state {
                                Text(state.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)
                }

                HStack {
                    Button {
                        onRequestAll()
                    } label: {
                        if isRequestingAll {
                            ProgressView()
                        } else {
                            Text("Request Retrieval (all)")
                        }
                    }
                    .disabled(isRequestingAll || group.secret.state == .discarding)
                    .buttonStyle(.bordered)
                    .font(.caption)

                    Spacer()

                    if group.secret.state == .discarding {
                        Text("Discarding…").font(.caption).foregroundStyle(.orange)
                        Button("Force Forget", role: .destructive, action: onForceForget)
                            .buttonStyle(.bordered)
                            .font(.caption)
                    } else {
                        Button("Discard", role: .destructive, action: onDiscard)
                            .buttonStyle(.bordered)
                            .font(.caption)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var healthBadge: some View {
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
    var label: LocalizedStringKey {
        switch self {
        case .pending: "Pending"
        case .approved: "Approved"
        case .denied: "Denied"
        }
    }
}

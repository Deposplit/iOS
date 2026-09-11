import hexagon
import SwiftUI

struct ShareDetailTarget: Identifiable, Hashable {
    let secret: Secret
    let share: ShareMetadata
    static func == (lhs: ShareDetailTarget, rhs: ShareDetailTarget) -> Bool { lhs.share.id == rhs.share.id }
    func hash(into hasher: inout Hasher) { hasher.combine(share.id) }
    var id: UUID { share.id }
}

/// Secrets this device split and handed out, one row per secret. The row summarises and nothing
/// more; holders and every action live on the secret's own screen, so that a list of ten secrets
/// does not become ten places where buttons appear and disappear.
struct DistributedTab: View {
    let groups: [SecretGroup]
    let onOpenSecret: (Secret) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if groups.isEmpty {
                ContentUnavailableView("No secrets split & shared yet", systemImage: "photo")
            } else {
                List {
                    ForEach(groups) { group in
                        Button {
                            onOpenSecret(group.secret)
                        } label: {
                            SecretSummaryRow(group: group)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct SecretSummaryRow: View {
    let group: SecretGroup

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.secret.label).font(.headline)
                HStack(spacing: 6) {
                    Text(group.secret.secretCreatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(group.holders.count) holder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    healthBadge
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var healthBadge: some View {
        switch group.health {
        case .destroying:
            Label("Destroying", systemImage: "trash").font(.caption2).foregroundStyle(.orange)
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

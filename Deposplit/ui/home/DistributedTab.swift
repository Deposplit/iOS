import hexagon
import SwiftUI

struct DistributedTab: View {
    let shares: [ShareMetadata]
    let contacts: [Contact]
    let syncWarning: Bool
    let onTap: (ShareMetadata) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if syncWarning {
                Label("Couldn't sync — showing cached data", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                Divider()
            }
            if shares.isEmpty {
                ContentUnavailableView("No distributed shares", systemImage: "lock.open")
            } else {
                List {
                    ForEach(shares) { share in
                        Button {
                            onTap(share)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(share.label).font(.headline)
                                Text(recipientName(for: share))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(share.secretCreatedAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func recipientName(for share: ShareMetadata) -> String {
        contacts.first(where: { $0.edPublicKey == share.recipientKey })?.pseudonym
            ?? share.recipientKey.base64URLEncoded.prefix(8) + "…"
    }
}

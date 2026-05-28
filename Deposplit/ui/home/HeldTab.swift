import hexagon
import SwiftUI

struct HeldTab: View {
    let shares: [HeldShare]
    let contacts: [Contact]
    let syncWarning: Bool

    var body: some View {
        if shares.isEmpty {
            ContentUnavailableView("No held shares", systemImage: "tray")
        } else {
            List {
                if syncWarning {
                    Label("Couldn't sync — showing cached data", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(Color.clear)
                }
                ForEach(shares) { share in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(share.label).font(.headline)
                        Text("From: \(senderName(for: share))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(share.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func senderName(for share: HeldShare) -> String {
        contacts.first(where: { $0.edPublicKey == share.senderKey })?.pseudonym
            ?? share.senderKey.base64URLEncoded.prefix(8) + "…"
    }
}

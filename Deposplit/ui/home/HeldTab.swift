import hexagon
import SwiftUI

struct HeldTab: View {
    let shares: [HeldShare]
    let contacts: ContactRepository

    var body: some View {
        if shares.isEmpty {
            ContentUnavailableView("No held shares", systemImage: "tray")
        } else {
            List(shares) { share in
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

    private func senderName(for share: HeldShare) -> String {
        contacts.getByEdKey(share.senderKey)?.pseudonym ?? share.senderKey.base64URLEncoded.prefix(8) + "…"
    }
}

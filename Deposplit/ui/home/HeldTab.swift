import hexagon
import SwiftUI

struct HeldTab: View {
    let shares: [HeldShare]
    let contacts: [Contact]

    var body: some View {
        VStack(spacing: 0) {
            if shares.isEmpty {
                ContentUnavailableView("No held shares", systemImage: "tray")
            } else {
                List {
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
    }

    private func senderName(for share: HeldShare) -> String {
        contacts.first(where: { $0.id == share.contactId })?.pseudonym
            ?? share.senderPseudonym
    }
}

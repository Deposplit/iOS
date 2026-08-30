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
                            if let subtitle = senderSubtitle(for: share) {
                                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            }
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
        contacts.first(where: { $0.id == share.contactId })?.displayName
            ?? share.senderPseudonym
    }

    // The contact's pseudonym, shown as a secondary line, but only when senderName
    // above is actually a nickname; nil otherwise (including when there's no local Contact at
    // all, in which case senderName already falls back to HeldShare's own senderPseudonym).
    private func senderSubtitle(for share: HeldShare) -> String? {
        contacts.first(where: { $0.id == share.contactId }).flatMap { $0.nickname != nil ? $0.pseudonym : nil }
    }
}

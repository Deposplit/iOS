import hexagon
import SwiftUI

struct HeldTab: View {
    let shares: [HeldShare]
    let contacts: [Contact]
    @Binding var sortOrder: HeldSortOrder
    let onDelete: (HeldShare) -> Void
    let onDeleteAllFromSender: (UUID) -> Void

    @State private var deleteTarget: HeldShare?

    var body: some View {
        VStack(spacing: 0) {
            if shares.isEmpty {
                ContentUnavailableView("No shares to keep safe yet", systemImage: "puzzlepiece")
            } else {
                List {
                    // Only once there is something to sort, as on Android and in phon. One Text per
                    // case keeps each a literal, and so a key the catalog translates.
                    Section {
                        Picker("Sort by", selection: $sortOrder) {
                            Text("Date").tag(HeldSortOrder.date)
                            Text("Label").tag(HeldSortOrder.label)
                            Text("From").tag(HeldSortOrder.sender)
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                    ForEach(sortedShares) { share in
                        HStack {
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
                            Spacer()
                            Button { deleteTarget = share } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Delete Share")
                                .foregroundStyle(.red)
                                // Otherwise a tap anywhere in the row would fire it.
                                .buttonStyle(.borderless)
                        }
                    }
                    // Swipe stays, because it is what a hand reaches for on iOS, but it opens the
                    // same dialog the trash button does rather than deleting outright.
                    .onDelete { offsets in
                        deleteTarget = offsets.map { sortedShares[$0] }.first
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete this share?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { share in
            Button("Delete Share", role: .destructive) {
                onDelete(share)
                deleteTarget = nil
            }
            if shares.filter({ $0.contactId == share.contactId }).count > 1 {
                Button("Delete All Shares from \(senderName(for: share))", role: .destructive) {
                    onDeleteAllFromSender(share.contactId)
                    deleteTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text("This will permanently remove this share from your device.")
        }
    }

    /// Newest first by date; labels and senders alphabetically, ignoring case, as Android does.
    private var sortedShares: [HeldShare] {
        switch sortOrder {
        case .date:
            shares.sorted { $0.createdAt > $1.createdAt }
        case .label:
            shares.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        case .sender:
            shares.sorted {
                senderName(for: $0).localizedCaseInsensitiveCompare(senderName(for: $1)) == .orderedAscending
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

import hexagon
import SwiftUI

private extension VerificationLevel {
    var badgeColor: Color {
        switch self {
        case .veryLow: .gray
        case .low: .yellow
        case .high: .blue
        case .veryHigh: .green
        }
    }
}

struct ContactsView: View {
    @State private var viewModel: ContactsViewModel
    @State private var showAddContact = false
    @State private var showQrScanner = false
    @State private var relinkTarget: Contact?
    @State private var compromiseTarget: Contact?
    @State private var deleteTarget: Contact?
    @State private var renameTarget: Contact?
    @State private var renameInput: String = ""
    @Environment(\.dismiss) private var dismiss

    private let contactManagement: any ContactManagement
    private let shareManagement: any ShareManagement

    init(contactManagement: any ContactManagement, shareManagement: any ShareManagement) {
        self.contactManagement = contactManagement
        self.shareManagement = shareManagement
        _viewModel = State(initialValue: ContactsViewModel(contactManagement: contactManagement, shareManagement: shareManagement))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.contacts.isEmpty {
                    ContentUnavailableView("No contacts yet", systemImage: "person.2.slash",
                                          description: Text("Add contacts to start sharing secrets."))
                } else {
                    List {
                        ForEach(viewModel.contacts) { contact in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(contact.displayName).font(.headline)
                                    if contact.verificationLevel > .veryLow {
                                        Text(contact.verificationLevel.displayName)
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(contact.verificationLevel.badgeColor.opacity(0.15), in: Capsule())
                                            .foregroundStyle(contact.verificationLevel.badgeColor)
                                    }
                                    if !contact.revokedVerifyKeys.isEmpty {
                                        Image(systemName: "exclamationmark.shield.fill")
                                            .foregroundStyle(.red)
                                            .font(.caption)
                                    }
                                    if viewModel.awaitingRelink.contains(contact.id) {
                                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                                            .foregroundStyle(.secondary)
                                            .font(.caption)
                                            .accessibilityLabel("\(contact.displayName) has not re-verified you yet")
                                    }
                                    if contact.heartbeatEmissionOptedOut {
                                        Image(systemName: "bell.slash")
                                            .foregroundStyle(.secondary)
                                            .font(.caption)
                                    }
                                }
                                if contact.nickname != nil {
                                    // The only name value that ever left the counterparty's
                                    // device — kept visible so it can actually be cross-checked.
                                    Text(contact.pseudonym)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(contact.verifyKey.base64URLEncoded.prefix(16) + "…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                actions(for: contact)
                            }
                        }
                        // Swipe stays, because it is what a hand reaches for on iOS, but it opens the
                        // same dialog the trash button does rather than deleting outright.
                        .onDelete { offsets in
                            deleteTarget = offsets.map { viewModel.contacts[$0] }.first
                        }
                    }
                }
            }
            .navigationTitle("Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showQrScanner = true
                        } label: {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        }
                        Button {
                            showAddContact = true
                        } label: {
                            Label("Enter Keys Manually", systemImage: "keyboard")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear { viewModel.load() }
            .sheet(isPresented: $showAddContact, onDismiss: { viewModel.load() }) {
                AddContactView(contactManagement: contactManagement)
            }
            .sheet(isPresented: $showQrScanner, onDismiss: { viewModel.load() }) {
                QrScanView(contactManagement: contactManagement)
            }
            .sheet(item: $relinkTarget, onDismiss: { viewModel.load() }) { contact in
                RelinkContactView(contact: contact, contactManagement: contactManagement, shareManagement: shareManagement)
            }
            .confirmationDialog(
                "Mark this contact's current key as compromised?",
                isPresented: Binding(get: { compromiseTarget != nil }, set: { if !$0 { compromiseTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Mark Compromised", role: .destructive) {
                    if let contact = compromiseTarget { viewModel.markKeyCompromised(contact) }
                    compromiseTarget = nil
                }
                Button("Cancel", role: .cancel) { compromiseTarget = nil }
            } message: {
                Text("Only do this if you have an out-of-band reason to believe \(compromiseTarget?.displayName ?? "this contact")'s key was stolen. Deposplit will refuse to auto-accept any future key rotation claiming continuity from it — you'll need to verify them fresh, in person or over a trusted channel, to reconnect.")
            }
            .confirmationDialog(
                "Delete this contact?",
                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Contact", role: .destructive) {
                    if let contact = deleteTarget { viewModel.delete(contact.id) }
                    deleteTarget = nil
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("Anything they hold for you stays with them — deleting only affects this device. But the shares linked to \(deleteTarget?.displayName ?? "this contact") lose that link, and adding them again creates a new contact rather than restoring this one.")
            }
            .alert(
                "Rename contact",
                isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
            ) {
                TextField("Nickname", text: $renameInput)
                Button("Save") {
                    if let contact = renameTarget { viewModel.rename(contact, nickname: renameInput) }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
        }
    }

    /// The same six actions Android and phon put on a contact row, in the same order. They used to
    /// live in a `.contextMenu`, which meant a long-press on a row that gave no sign it was
    /// pressable — the actions were all there and none of them was findable.
    ///
    /// Icon-only, so each carries the label its menu entry used to show and a screen reader still
    /// hears a verb rather than a symbol name.
    @ViewBuilder
    private func actions(for contact: Contact) -> some View {
        HStack(spacing: 18) {
            // Only where it is relevant: the entry would be meaningless noise on a contact who
            // never lost sight of this device's key.
            if viewModel.awaitingRelink.contains(contact.id) {
                Button { viewModel.markRelinked(contact.id) } label: { Image(systemName: "checkmark") }
                    .accessibilityLabel("Mark as Re-verified")
            }
            Button {
                renameInput = contact.nickname ?? ""
                renameTarget = contact
            } label: {
                Image(systemName: "pencil")
            }
            .accessibilityLabel("Rename")
            Button { relinkTarget = contact } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .accessibilityLabel("Relink (Key Changed)")
            // Low-stakes and reversible, so no confirmation, unlike the two beside it.
            Button { viewModel.toggleHeartbeatEmission(contact) } label: {
                Image(systemName: contact.heartbeatEmissionOptedOut ? "bell" : "bell.slash")
            }
            .accessibilityLabel(heartbeatLabel(for: contact))
            Button { compromiseTarget = contact } label: { Image(systemName: "exclamationmark.shield") }
                .accessibilityLabel("Mark Key Compromised")
                .foregroundStyle(.red)
            Button { deleteTarget = contact } label: { Image(systemName: "trash") }
                .accessibilityLabel("Delete Contact")
                .foregroundStyle(.red)
        }
        .font(.body)
        // Without this every one of them fires on a tap anywhere in the row: SwiftUI gives a List
        // row a single tap target unless each button opts out of it.
        .buttonStyle(.borderless)
        .padding(.top, 6)
    }

    /// Typed rather than inlined as a ternary: two string literals in a ternary infer `String`, and
    /// a `String` handed to `accessibilityLabel` is interpolated instead of looked up, which loses
    /// the translation silently.
    private func heartbeatLabel(for contact: Contact) -> LocalizedStringKey {
        contact.heartbeatEmissionOptedOut ? "Resume Heartbeats" : "Pause Heartbeats"
    }
}

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
    @State private var renameTarget: Contact?
    @State private var renameInput: String = ""
    @Environment(\.dismiss) private var dismiss

    private let contactManagement: any ContactManagement
    private let purchaseStore: StoreKitPurchaseStore
    private let shareManagement: any ShareManagement

    init(contactManagement: any ContactManagement, shareManagement: any ShareManagement, purchaseStore: StoreKitPurchaseStore) {
        self.purchaseStore = purchaseStore
        self.contactManagement = contactManagement
        self.shareManagement = shareManagement
        _viewModel = State(initialValue: ContactsViewModel(contactManagement: contactManagement, shareManagement: shareManagement))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.contacts.isEmpty {
                    ContentUnavailableView("No contacts", systemImage: "person.crop.circle.badge.plus",
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
                                        Image(systemName: "heart.slash")
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
                            }
                            .contextMenu {
                                // Only where it is relevant: the entry would be meaningless noise on
                                // a contact who never lost sight of this device's key.
                                if viewModel.awaitingRelink.contains(contact.id) {
                                    Button {
                                        viewModel.markRelinked(contact.id)
                                    } label: {
                                        Label("Mark as Re-verified", systemImage: "checkmark")
                                    }
                                }
                                Button {
                                    renameInput = contact.nickname ?? ""
                                    renameTarget = contact
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button {
                                    relinkTarget = contact
                                } label: {
                                    Label("Relink (Key Changed)", systemImage: "arrow.triangle.2.circlepath")
                                }
                                Button(role: .destructive) {
                                    compromiseTarget = contact
                                } label: {
                                    Label("Mark Key Compromised", systemImage: "exclamationmark.shield")
                                }
                                // Low-stakes and reversible, no confirmation dialog.
                                Button {
                                    viewModel.toggleHeartbeatEmission(contact)
                                } label: {
                                    if contact.heartbeatEmissionOptedOut {
                                        Label("Resume Heartbeats", systemImage: "heart.fill")
                                    } else {
                                        Label("Pause Heartbeats", systemImage: "heart.slash")
                                    }
                                }
                            }
                        }
                        .onDelete { viewModel.delete(at: $0) }
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
                AddContactView(contactManagement: contactManagement, purchaseStore: purchaseStore)
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
}

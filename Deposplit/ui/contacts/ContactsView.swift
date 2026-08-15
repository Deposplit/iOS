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
    @Environment(\.dismiss) private var dismiss

    private let contactManagement: any ContactManagement
    private let shareManagement: any ShareManagement

    init(contactManagement: any ContactManagement, shareManagement: any ShareManagement) {
        self.contactManagement = contactManagement
        self.shareManagement = shareManagement
        _viewModel = State(initialValue: ContactsViewModel(contactManagement: contactManagement))
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
                                    Text(contact.pseudonym).font(.headline)
                                    if contact.verificationLevel > .veryLow {
                                        Text(contact.verificationLevel.displayName)
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(contact.verificationLevel.badgeColor.opacity(0.15), in: Capsule())
                                            .foregroundStyle(contact.verificationLevel.badgeColor)
                                    }
                                }
                                Text(contact.edPublicKey.base64URLEncoded.prefix(16) + "…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Button {
                                    relinkTarget = contact
                                } label: {
                                    Label("Relink (Key Changed)", systemImage: "arrow.triangle.2.circlepath")
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
                AddContactView(contactManagement: contactManagement)
            }
            .sheet(isPresented: $showQrScanner, onDismiss: { viewModel.load() }) {
                QrScanView(contactManagement: contactManagement)
            }
            .sheet(item: $relinkTarget, onDismiss: { viewModel.load() }) { contact in
                RelinkContactView(contact: contact, contactManagement: contactManagement, shareManagement: shareManagement)
            }
        }
    }
}

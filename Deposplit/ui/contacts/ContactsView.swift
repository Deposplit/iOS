import hexagon
import SwiftUI

struct ContactsView: View {
    @State private var viewModel: ContactsViewModel
    @State private var showAddContact = false
    @State private var showQrScanner = false
    @Environment(\.dismiss) private var dismiss

    private let repository: ContactRepository

    init(repository: ContactRepository) {
        self.repository = repository
        _viewModel = State(initialValue: ContactsViewModel(repository: repository))
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
                                    if contact.verificationLevel == .verified {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundStyle(.green)
                                            .font(.caption)
                                    }
                                }
                                Text(contact.edPublicKey.base64URLEncoded.prefix(16) + "…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                AddContactView(repository: repository)
            }
            .sheet(isPresented: $showQrScanner, onDismiss: { viewModel.load() }) {
                QrScanView(repository: repository)
            }
        }
    }
}

import hexagon
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var showImporter = false
    @State private var showRegenerateConfirmation = false
    @Environment(\.dismiss) private var dismiss

    init(relaySettings: any RelaySettings, catalogManagement: any CatalogManagement, shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        _viewModel = State(initialValue: SettingsViewModel(relaySettings: relaySettings, catalogManagement: catalogManagement, shareManagement: shareManagement, contactManagement: contactManagement))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $viewModel.relayBaseUrl)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Default relay")
                } footer: {
                    Text("Used for contacts without a BYOR override, and advertised in your own QR code.")
                }
                Section {
                    Button("Reset to Default", role: .destructive) {
                        viewModel.resetToDefault()
                    }
                }
                Section {
                    Button("Export Catalog…") {
                        viewModel.prepareCatalogExport()
                    }
                    if let url = viewModel.catalogExportURL {
                        ShareLink(item: url) {
                            Label("Share Export", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("Import Catalog…") {
                        showImporter = true
                    }
                    if let message = viewModel.catalogImportMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Catalog Backup")
                } footer: {
                    Text("Contacts, verification levels, and secret metadata only — never shares or private keys.")
                }
                Section {
                    Button("Regenerate My Identity", role: .destructive) {
                        showRegenerateConfirmation = true
                    }
                    .disabled(viewModel.isRegeneratingIdentity)
                    if viewModel.isRegeneratingIdentity {
                        ProgressView()
                    }
                    if let message = viewModel.regenerateIdentityMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Identity")
                } footer: {
                    Text("Generates a brand-new keypair for this device and automatically notifies all your contacts. Requests still pending with someone else at this moment may become unreachable afterward — best to let those settle first. This cannot be undone.")
                }
            }
            .confirmationDialog(
                "Regenerate your identity?",
                isPresented: $showRegenerateConfirmation,
                titleVisibility: .visible
            ) {
                Button("Regenerate", role: .destructive) {
                    Task { await viewModel.regenerateIdentity() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This creates a new key pair and notifies \(viewModel.contactCount) contact(s). Any request currently pending with someone else may be lost.")
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result {
                    viewModel.importCatalog(from: url)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        viewModel.save()
                        dismiss()
                    }
                }
            }
        }
    }
}

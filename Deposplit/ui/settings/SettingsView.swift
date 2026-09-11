import hexagon
import SwiftUI
// For `openNotificationSettingsURLString` alone — a string constant with no SwiftUI counterpart,
// and the only alternative is hard-coding an undocumented URL.
import UIKit
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var showImporter = false
    @State private var showRegenerateConfirmation = false
    /// nil until the first read comes back, so the section shows no state rather than the wrong one.
    @State private var notificationStatus: UNAuthorizationStatus?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private let purchaseStore: StoreKitPurchaseStore

    init(relaySettings: any RelaySettings, catalogManagement: any CatalogManagement, shareManagement: any ShareManagement, contactManagement: any ContactManagement, purchaseStore: StoreKitPurchaseStore) {
        self.purchaseStore = purchaseStore
        _viewModel = State(initialValue: SettingsViewModel(relaySettings: relaySettings, purchases: purchaseStore, catalogManagement: catalogManagement, shareManagement: shareManagement, contactManagement: contactManagement))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if purchaseStore.isUnlocked {
                        TextField("https://…", text: $viewModel.relayBaseUrl)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        // Read-only rather than hidden: which relay this device uses is worth
                        // knowing even when changing it is not on offer.
                        Text(verbatim: viewModel.relayBaseUrl)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Default relay")
                } footer: {
                    if purchaseStore.isUnlocked {
                        Text("Used for contacts without a BYOR override, and advertised in your own QR code.")
                    } else {
                        Text("Used for contacts without a BYOR override, and advertised in your own QR code. Choosing your own default relay is part of Premium.")
                    }
                }
                if purchaseStore.isUnlocked {
                    Section {
                        Button("Reset to Default", role: .destructive) {
                            viewModel.resetToDefault()
                        }
                    }
                }
                Section {
                    NavigationLink {
                        PaywallView(store: purchaseStore)
                    } label: {
                        if purchaseStore.isUnlocked {
                            Label("Premium is unlocked on this device.", systemImage: "checkmark.seal")
                        } else {
                            Text("See Premium")
                        }
                    }
                } header: {
                    Text("Deposplit Premium")
                } footer: {
                    if !purchaseStore.isUnlocked {
                        Text("Not unlocked: \(SecretLimits.freeTierMaxActiveSecrets) secrets at a time, and deposplit.com as the relay.")
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
                // Nothing to toggle: iOS owns this switch and offers it per app under iCloud
                // Backup. What the app owes the user is the consequence, because the redundancy
                // lost by excluding Deposplit is other people's, not theirs.
                Section {
                    Text("Deposplit's data on this phone — your contacts, your secrets' details, and the shares you hold for other people — is included in your device backup, so it survives a phone switch. Your private keys are not: they cannot leave this phone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Device Backup")
                } footer: {
                    Text("iCloud Backup is encrypted, but end-to-end only with Advanced Data Protection turned on. You can exclude Deposplit under iCloud Backup in Settings. If you do, a new iPhone starts empty — the people whose shares you guard lose that redundancy, and your new iPhone has no record to tell them with.")
                }
                // Nothing to toggle here either: iOS owns this switch. What the app owes is what
                // the notice is for, whether it is on, and a way to the system page for somebody
                // who has no other route to it — including somebody who has never been asked, who
                // does not appear under Settings → Notifications at all yet.
                Section {
                    Text("Deposplit can tell you when a contact needs a share you are keeping safe, even while the app is closed. The notice names nobody and no secret, so a locked screen gives nothing away.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    switch notificationStatus {
                    case .none:
                        EmptyView()
                    case .notDetermined:
                        Text("Not turned on yet. Without it you learn of a request only when you next open Deposplit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Turn On Notifications") {
                            Task {
                                await RequestNotifier.requestAuthorization()
                                notificationStatus = await RequestNotifier.authorizationStatus()
                            }
                        }
                    case .denied:
                        Text("Turned off. Without it you learn of a request only when you next open Deposplit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Notification settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                openURL(url)
                            }
                        }
                    default:
                        Text("Turned on for this app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Notifications")
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
                Text("This creates a new key pair and notifies \(viewModel.contactCount) contact(s). A share already on its way to you can still be collected afterwards; a contact who cannot be reached now will not learn of the new key.")
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result {
                    viewModel.importCatalog(from: url)
                }
            }
            .task { notificationStatus = await RequestNotifier.authorizationStatus() }
            // Re-read on return, because the way to change it is to leave for the system page and
            // come back — a line that still said "turned off" afterwards would be the screen
            // calling the reader's own action a no-op.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { notificationStatus = await RequestNotifier.authorizationStatus() }
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

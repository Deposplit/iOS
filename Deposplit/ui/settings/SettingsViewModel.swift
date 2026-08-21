import hexagon
import Foundation

@Observable
final class SettingsViewModel {

    var relayBaseUrl: String
    var catalogExportURL: URL?
    var catalogImportMessage: String?

    /// Item 9's identity-regen trigger. `contactCount` is pre-fetched so the confirmation dialog
    /// can tell the user how many contacts will be notified before they commit.
    private(set) var contactCount = 0
    private(set) var isRegeneratingIdentity = false
    var regenerateIdentityMessage: String?

    private let relaySettings: any RelaySettings
    private let catalogManagement: any CatalogManagement
    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement

    init(relaySettings: any RelaySettings, catalogManagement: any CatalogManagement, shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        self.relaySettings = relaySettings
        self.catalogManagement = catalogManagement
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
        self.relayBaseUrl = relaySettings.defaultRelayBaseURL()
        self.contactCount = (try? contactManagement.listContacts().count) ?? 0
    }

    func save() {
        let trimmed = relayBaseUrl.trimmingCharacters(in: .whitespaces)
        relaySettings.setDefaultRelayBaseURL(trimmed.isEmpty ? nil : trimmed)
    }

    func resetToDefault() {
        relaySettings.setDefaultRelayBaseURL(nil)
        relayBaseUrl = relaySettings.defaultRelayBaseURL()
    }

    /// Writes a fresh catalog export to a temp file and returns its URL for `ShareLink` — a
    /// self-managed, non-secret backup (contacts, verification levels, `ShareMetadata`/`Secret`
    /// records; never shares or private keys). See item 8.
    func prepareCatalogExport() {
        do {
            let data = try catalogManagement.exportCatalog()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("deposplit-catalog-\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: url, options: .atomic)
            catalogExportURL = url
        } catch {
            catalogImportMessage = error.localizedDescription
        }
    }

    /// Item 9's identity-regen trigger. Best-effort drains pending relay state under the *old*
    /// identity, notifies every contact of the new key, then activates it — see
    /// `ShareService.regenerateIdentity`'s doc comment for why the ordering matters. Any request
    /// still pending with a counterparty at this exact moment may become unreachable afterward
    /// (surfaced in the confirmation copy, not repeated here).
    func regenerateIdentity() async {
        isRegeneratingIdentity = true
        defer { isRegeneratingIdentity = false }
        do {
            let result = try await shareManagement.regenerateIdentity()
            regenerateIdentityMessage = String(localized: "Notified \(result.notifiedContacts) of \(result.totalContacts) contact(s).")
        } catch {
            regenerateIdentityMessage = error.localizedDescription
        }
    }

    func importCatalog(from url: URL) {
        do {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let added = try catalogManagement.importCatalog(data)
            catalogImportMessage = String(localized: "Imported \(added) new contact(s).")
        } catch {
            catalogImportMessage = error.localizedDescription
        }
    }
}

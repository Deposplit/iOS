import hexagon
import Foundation

@Observable
final class SettingsViewModel {

    var relayBaseUrl: String
    var relayBaseUrlError: String?
    var catalogExportURL: URL?
    var catalogImportMessage: String?

    /// The identity-regeneration trigger. `contactCount` is pre-fetched so the confirmation dialog
    /// can tell the user how many contacts will be notified before they commit.
    private(set) var contactCount = 0
    private(set) var isRegeneratingIdentity = false
    var regenerateIdentityMessage: String?

    private let relaySettings: any RelaySettings
    private let purchases: any PurchaseRepository
    private let catalogManagement: any CatalogManagement
    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement

    init(relaySettings: any RelaySettings, purchases: any PurchaseRepository, catalogManagement: any CatalogManagement, shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        self.relaySettings = relaySettings
        self.purchases = purchases
        self.catalogManagement = catalogManagement
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
        self.relayBaseUrl = relaySettings.defaultRelayBaseURL()
        self.contactCount = (try? contactManagement.listContacts().count) ?? 0
    }

    /// No-op without Premium: the field is not editable then, and Done calls this unconditionally.
    /// False when the field names no relay, so that Done can stay open and say so: this default is
    /// what every contact without an override is reached through, and what this device's QR
    /// code hands out.
    func save() -> Bool {
        guard purchases.isPremium() else { return true }
        let trimmed = relayBaseUrl.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            relaySettings.setDefaultRelayBaseURL(nil)
            return true
        }
        guard let base = RelayBaseUrl.parse(trimmed) else {
            relayBaseUrlError = String(localized: "The relay must be an address starting with http:// or https://.")
            return false
        }
        relaySettings.setDefaultRelayBaseURL(base)
        return true
    }

    func resetToDefault() {
        relayBaseUrlError = nil
        relaySettings.setDefaultRelayBaseURL(nil)
        relayBaseUrl = relaySettings.defaultRelayBaseURL()
    }

    /// Writes a fresh catalog export to a temp file and returns its URL for `ShareLink` — a
    /// self-managed, non-secret backup (contacts, verification levels, `ShareMetadata`/`Secret`
    /// records; never shares or private keys).
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

    /// The identity-regeneration trigger. Best-effort drains pending relay state under the *old*
    /// identity, notifies every contact of the new key, then activates it — see
    /// `ShareService.regenerateIdentity`'s doc comment for why the ordering matters. A drain that
    /// could not reach every relay is reported rather than swallowed: it no longer risks losing a
    /// share, since the displaced key is retained one generation, but the user is told what was
    /// skipped instead of the rotation quietly deciding for them.
    func regenerateIdentity() async {
        isRegeneratingIdentity = true
        defer { isRegeneratingIdentity = false }
        do {
            let result = try await shareManagement.regenerateIdentity()
            var message = String(localized: "Notified \(result.notifiedContacts) of \(result.totalContacts) contact(s).")
            if !result.drainSucceeded {
                message += " " + String(localized: "Some shares on their way to you could not be collected before the switch to the new keys. They will still arrive later, on their own.")
            }
            regenerateIdentityMessage = message
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

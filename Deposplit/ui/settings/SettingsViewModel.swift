import hexagon
import Foundation

@Observable
final class SettingsViewModel {

    var relayBaseUrl: String
    var catalogExportURL: URL?
    var catalogImportMessage: String?

    private let relaySettings: any RelaySettings
    private let catalogManagement: any CatalogManagement

    init(relaySettings: any RelaySettings, catalogManagement: any CatalogManagement) {
        self.relaySettings = relaySettings
        self.catalogManagement = catalogManagement
        self.relayBaseUrl = relaySettings.defaultRelayBaseURL()
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

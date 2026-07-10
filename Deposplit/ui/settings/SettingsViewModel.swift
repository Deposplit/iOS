import hexagon
import Foundation

@Observable
final class SettingsViewModel {

    var relayBaseUrl: String

    private let relaySettings: any RelaySettings

    init(relaySettings: any RelaySettings) {
        self.relaySettings = relaySettings
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
}

import hexagon
import Foundation

final class UserDefaultsRelaySettings: RelaySettings {

    private let key = "defaultRelayBaseURL"

    func defaultRelayBaseURL() -> String {
        UserDefaults.standard.string(forKey: key) ?? RelayDefaults.fallbackBaseURL
    }

    func setDefaultRelayBaseURL(_ url: String?) {
        if let url, !url.trimmingCharacters(in: .whitespaces).isEmpty {
            UserDefaults.standard.set(url, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

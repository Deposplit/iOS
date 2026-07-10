import Foundation

/// The device's runtime-configurable default relay — used by `ShareRelayResolver` for any
/// `Contact` without an explicit `relayBaseUrl` override, and embedded in this device's own
/// outgoing QR codes so contacts know where to deposit shares for it.
public protocol RelaySettings {
    func defaultRelayBaseURL() -> String

    /// Passing nil resets to the built-in fallback.
    func setDefaultRelayBaseURL(_ url: String?)
}

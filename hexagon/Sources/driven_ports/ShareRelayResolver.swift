import Foundation

/// Resolves which `ShareRelay` to use for a given contact's BYOR override — a factory/cache, not
/// a fan-out mechanism (fan-out across multiple relays is a ShareService-level policy decision,
/// not an infrastructure concern). `nil` resolves to the device's configured default relay
/// (`RelaySettings`).
public protocol ShareRelayResolver {
    func resolve(_ relayBaseUrl: String?) -> any ShareRelay
}

import Foundation

/// Resolves which `ShareRelay` to use for a given contact's BYOR override — a factory/cache, not
/// a fan-out mechanism (fan-out across multiple relays is a ShareService-level policy decision,
/// not an infrastructure concern). `nil` resolves to the device's configured default relay
/// (`RelaySettings`).
public protocol ShareRelayResolver {
    /// Memoized per resolved URL: two calls that resolve to the same relay must return the *same*
    /// instance. Callers dedupe their fan-out list on the resolved relay, which is the only way to
    /// notice that a contact pinned to this device's own default names the relay `nil` already
    /// names — so an implementation that returns a fresh instance each time makes every relay row
    /// arrive twice.
    func resolve(_ relayBaseUrl: String?) -> any ShareRelay
}

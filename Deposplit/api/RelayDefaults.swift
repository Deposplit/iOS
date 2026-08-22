import Foundation

/// Fallback used until the user configures a different default relay via Settings — fully
/// decoupled from build-configuration machinery, matching Android's `RelayDefaults.kt`. Point a
/// debug/simulator build at a local `sbt run` instance via the Settings screen's default-relay
/// editor instead of a compile-time switch.
enum RelayDefaults {
    static let fallbackBaseURL = "https://api.deposplit.com"
}

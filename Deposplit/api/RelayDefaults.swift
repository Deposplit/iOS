import Foundation

/// Fallback used until the user configures a different default relay via Settings.
enum RelayDefaults {
    #if DEBUG
    static let fallbackBaseURL = "http://localhost:9000"
    #else
    static let fallbackBaseURL = "https://api.deposplit.com"
    #endif
}

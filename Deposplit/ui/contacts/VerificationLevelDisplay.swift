import hexagon
import SwiftUI

// Shared label/guidance/color mapping for VerificationLevel, used by ContactsView, AddContactView
// and RelinkContactView. LocalizedStringKey, not String, so Text looks each one up in the catalog.
extension VerificationLevel {
    var displayName: LocalizedStringKey {
        switch self {
        case .veryLow: "Very Low"
        case .low: "Low"
        case .high: "High"
        case .veryHigh: "Very High"
        }
    }

    /// What this level asserts.
    var guidance: LocalizedStringKey {
        switch self {
        case .veryLow: "Untrusted channel, no live proof — e.g. e-mail, LinkedIn, a business card."
        case .low: "One assurance, not both — e.g. a Signal message from a known contact, or a video call where they show their QR."
        case .high: "Both assurances — e.g. a verified-safety-number video call where they show their QR."
        case .veryHigh: "Physical co-presence — you scanned their QR code in person."
        }
    }

    var badgeColor: Color {
        switch self {
        case .veryLow: .gray
        case .low: .yellow
        case .high: .accentColor
        case .veryHigh: .green
        }
    }
}

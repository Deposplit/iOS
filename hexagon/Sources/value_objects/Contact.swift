import Foundation

/// Four-level ordinal verification model — see deposplit.com/CLAUDE.md "What is next" item 6.
/// Derived from a trusted-channel × proof-of-life lattice; the two incomparable middle cells are
/// merged into `low`, so the order is simply the count of independent assurances present (0/1/2),
/// or 3 for physical co-presence.
public enum VerificationLevel: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
    case veryLow, low, high, veryHigh

    public var displayName: String {
        switch self {
        case .veryLow: "Very Low"
        case .low: "Low"
        case .high: "High"
        case .veryHigh: "Very High"
        }
    }

    /// What this level asserts, mirroring the examples in CLAUDE.md's item 6 table.
    public var guidance: String {
        switch self {
        case .veryLow: "Untrusted channel, no live proof — e.g. e-mail, LinkedIn, a business card."
        case .low: "One assurance, not both — e.g. a Signal message from a known contact, or a video call where they show their QR."
        case .high: "Both assurances — e.g. a verified-safety-number video call where they show their QR."
        case .veryHigh: "Physical co-presence — you scanned their QR code in person."
        }
    }

    private var rank: Int {
        switch self {
        case .veryLow: 0
        case .low: 1
        case .high: 2
        case .veryHigh: 3
        }
    }

    public static func < (lhs: VerificationLevel, rhs: VerificationLevel) -> Bool { lhs.rank < rhs.rank }
}

public struct Contact: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let pseudonym: String
    public let edPublicKey: Data
    public let xPublicKey: Data
    public let verificationLevel: VerificationLevel
    public let verifiedAt: Date?
    public let addedAt: Date
    /// BYOR override — nil means "use the device's configured default relay". A pinned snapshot
    /// at contact-add time, not a live pointer, same TOFU trust model as the public keys.
    public let relayBaseUrl: String?

    public init(
        id: UUID, pseudonym: String,
        edPublicKey: Data, xPublicKey: Data,
        verificationLevel: VerificationLevel, verifiedAt: Date?, addedAt: Date,
        relayBaseUrl: String? = nil
    ) {
        self.id = id
        self.pseudonym = pseudonym
        self.edPublicKey = edPublicKey
        self.xPublicKey = xPublicKey
        self.verificationLevel = verificationLevel
        self.verifiedAt = verifiedAt
        self.addedAt = addedAt
        self.relayBaseUrl = relayBaseUrl
    }
}

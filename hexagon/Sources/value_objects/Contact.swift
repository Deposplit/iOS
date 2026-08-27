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

public struct Contact: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let pseudonym: String
    public let verifyKey: Data
    public let encKey: Data
    public let verificationLevel: VerificationLevel
    public let verifiedAt: Date?
    public let addedAt: Date
    /// BYOR override — nil means "use the device's configured default relay". A pinned snapshot
    /// at contact-add time, not a live pointer, same TOFU trust model as the public keys.
    public let relayBaseUrl: String?
    /// Item 10 — historical verify keys locally flagged compromised via `ContactManagement
    /// .markKeyCompromised`, out-of-band. A signed rotation notice claiming continuity from any
    /// key in this set is refused auto-accept (see `ShareManagement`'s rotation-processing) —
    /// revocation is socially anchored, so only a fresh human-verified relink can move the
    /// contact forward once a key lands here. Never cleared automatically.
    public let revokedVerifyKeys: [Data]
    /// Item 10 — when `verifyKey` (or `encKey`) last changed via `updateContact`, whether
    /// through a human-verified relink (item 8) or an auto-accepted rotation (item 9). `nil`
    /// until the first key change. Surfaced on the retrieve-approval screen as "this requester's
    /// key changed N days ago" — the attack signature item 10 hardens against is key change
    /// followed by a quick retrieval request.
    public let keyChangedAt: Date?
    /// Item 12, owner role — this contact (as a holder of one of my secrets) sent a signed
    /// opt-out notice at this time: "my silence from here on is not a loss signal." `nil` means
    /// either never opted out, or opted back in (cleared on the next non-opted-out heartbeat).
    /// Durable and local — captured the instant the notice is observed, since the relay may lose
    /// its state at any time and must never be relied on to keep this alert alive.
    public let heartbeatOptedOutAt: Date?
    /// Item 12, holder role — when this device last pushed a custodial heartbeat *to* this
    /// contact (who is the owner in that relationship). Drives `ShareService`'s opportunistic
    /// per-sender emission cadence; reset to `nil` by `setHeartbeatEmissionOptedOut` so a toggled
    /// preference reaches the contact on the very next poll rather than waiting out the interval.
    public let lastHeartbeatSentAt: Date?
    /// Item 12, holder role — this device's own choice to stop heartbeating this contact (who is
    /// the owner in that relationship). Defaults to `false` (heartbeating is opt-out, not
    /// opt-in). When `true`, `ShareService`'s emission loop still visits this contact on its
    /// normal cadence but sends a signed opt-out notice instead of a normal heartbeat.
    public let heartbeatEmissionOptedOut: Bool
    /// Item 14 — the signing + key-agreement algorithm pairing `verifyKey`/`encKey` use. Defaults
    /// to `.current` for constructor convenience (every contact really is on that one suite
    /// today, not a placeholder) — `addFromQr`/`updateContact` pass the value actually asserted
    /// by the contact's QR payload or rotation notice.
    public let cipherSuite: CipherSuite
    /// Item 15 — a purely local, optional label to disambiguate contacts who share the same
    /// sender-asserted pseudonym (e.g. two different "Paul"s). Never transmitted anywhere — not
    /// in the QR/link payload, any relay row, or any rotation/heartbeat/inventory push. Trimmed
    /// and blank-collapsed-to-nil by `ContactService` before it ever reaches this field.
    public let nickname: String?

    public init(
        id: UUID, pseudonym: String,
        verifyKey: Data, encKey: Data,
        verificationLevel: VerificationLevel, verifiedAt: Date?, addedAt: Date,
        relayBaseUrl: String? = nil,
        revokedVerifyKeys: [Data] = [],
        keyChangedAt: Date? = nil,
        heartbeatOptedOutAt: Date? = nil,
        lastHeartbeatSentAt: Date? = nil,
        heartbeatEmissionOptedOut: Bool = false,
        cipherSuite: CipherSuite = .current,
        nickname: String? = nil
    ) {
        self.id = id
        self.pseudonym = pseudonym
        self.verifyKey = verifyKey
        self.encKey = encKey
        self.verificationLevel = verificationLevel
        self.verifiedAt = verifiedAt
        self.addedAt = addedAt
        self.relayBaseUrl = relayBaseUrl
        self.revokedVerifyKeys = revokedVerifyKeys
        self.keyChangedAt = keyChangedAt
        self.heartbeatOptedOutAt = heartbeatOptedOutAt
        self.lastHeartbeatSentAt = lastHeartbeatSentAt
        self.heartbeatEmissionOptedOut = heartbeatEmissionOptedOut
        self.cipherSuite = cipherSuite
        self.nickname = nickname
    }

    /// Item 15 — the display-precedence policy ("nickname when set, else pseudonym") lives once
    /// on the domain object rather than being re-derived at every one of the app's render sites.
    public var displayName: String { nickname ?? pseudonym }
}

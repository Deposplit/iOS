import Foundation

/// Item 12's signed custodial-heartbeat push addressed to this device — a holder's proactive
/// "still guarding {secretIds} for you" notice (or, when `optedOut` is true, a signed "my
/// silence from here on is not a loss signal" notice). Deliberately not a `ShareRequest`: no
/// singular `secretId`, no consent phase — and unlike `KeyRotation`, never consumed-and-deleted:
/// the relay keeps only the latest heartbeat per (holder, owner) pair, so this is read
/// repeatedly, not drained. See `PayloadCanonical.forHeartbeat` for the exact bytes signed, and
/// deposplit.com/CLAUDE.md "What is next" item 12.
public struct CustodyHeartbeat: Identifiable, Equatable {
    public let id: UUID
    public let holderKey: Data
    public let ownerKey: Data
    public let secretIds: [UUID]
    public let optedOut: Bool
    public let signature: Data
    public let createdAt: Date

    public init(id: UUID, holderKey: Data, ownerKey: Data, secretIds: [UUID], optedOut: Bool, signature: Data, createdAt: Date) {
        self.id = id
        self.holderKey = holderKey
        self.ownerKey = ownerKey
        self.secretIds = secretIds
        self.optedOut = optedOut
        self.signature = signature
        self.createdAt = createdAt
    }
}

import Foundation

public enum Role: String {
    case sender, recipient
}

/// The kind of thing that happened (or is being asked to happen) to a share, phrased as a
/// neutral transaction noun rather than either party's verb. Naming from a single named actor's
/// point of view (Alice's, or Bob's) breaks down because the actor genuinely alternates — Alice
/// always opens deposit/retrieval/removal, but the *holder* opens inventory (holder → owner).
public enum ShareTransactionType: String {
    case deposit, retrieval, removal
    // A holder-initiated metadata-only push during identity recovery — not consent-gated, unlike
    // the other three.
    case inventory
}

public enum ShareRequestState: String {
    case pending, approved, denied
    /// Deposit-only: the recipient unilaterally stopped holding the share. A best-effort
    /// tombstone, not authoritative — see `ShareRelay.withdrawShareRequests`.
    case withdrawn
}

/// Per-share record on the sender's device — one per holder of a `Secret`. Normalized to
/// reference its parent `Secret` (by `secretId`) rather than duplicating `label`/
/// `secretCreatedAt`.
public struct ShareMetadata: Identifiable, Equatable, Hashable, Codable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public let id: UUID           // Deposit request ID
    public let secretId: UUID
    // The holder's stable local contact id — not their Ed25519 key — so this record survives a
    // holder key rotation/recovery.
    public let contactId: UUID
    // Last proof-of-custody observed for this holder: a relay-observed pickup/retrieve
    // approval, or a processed heartbeat, whichever is most recent. `nil` until the first such
    // observation (e.g. right after deposit(), before the holder has picked up). Drives the
    // freshness-bucket health model — see `CustodyHeartbeatTuning`.
    public let lastConfirmedAt: Date?

    public init(id: UUID, secretId: UUID, contactId: UUID, lastConfirmedAt: Date? = nil) {
        self.id = id
        self.secretId = secretId
        self.contactId = contactId
        self.lastConfirmedAt = lastConfirmedAt
    }
}

public struct ShareRequest: Identifiable, Equatable {
    public let id: UUID
    public let secretId: UUID
    public let senderKey: Data
    public let recipientKey: Data
    public let label: String
    public let secretCreatedAt: Date
    public let transactionType: ShareTransactionType
    public let state: ShareRequestState
    public let shareId: UUID?
    public let requestedAt: Date
    public let respondedAt: Date?
    public let ciphertext: Data?
    // SSS threshold/share-count and the sender's declared media type — all populated for
    // deposit/inventory, nil for retrieval/removal.
    public let k: Int?
    public let n: Int?
    public let mimeType: MimeType?
    /// Ed25519 signature over `PayloadCanonical.forOpen` — see that type for what's signed.
    public let senderSignature: Data
    /// Ed25519 signature over `PayloadCanonical.forRespond`; nil while pending.
    public let recipientSignature: Data?

    public init(
        id: UUID, secretId: UUID, senderKey: Data, recipientKey: Data,
        label: String, secretCreatedAt: Date,
        transactionType: ShareTransactionType, state: ShareRequestState,
        shareId: UUID?, requestedAt: Date, respondedAt: Date?, ciphertext: Data?,
        k: Int? = nil, n: Int? = nil, mimeType: MimeType? = nil,
        senderSignature: Data, recipientSignature: Data?
    ) {
        self.id = id
        self.secretId = secretId
        self.senderKey = senderKey
        self.recipientKey = recipientKey
        self.label = label
        self.secretCreatedAt = secretCreatedAt
        self.transactionType = transactionType
        self.state = state
        self.shareId = shareId
        self.requestedAt = requestedAt
        self.respondedAt = respondedAt
        self.ciphertext = ciphertext
        self.k = k
        self.n = n
        self.mimeType = mimeType
        self.senderSignature = senderSignature
        self.recipientSignature = recipientSignature
    }
}

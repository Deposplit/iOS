import Foundation

public enum Role: String {
    case sender, recipient
}

public enum ShareRequestType: String {
    case pickUp = "pick_up", retrieve, delete
}

public enum ShareRequestState: String {
    case pending, approved, denied
}

public struct ShareMetadata: Identifiable, Equatable, Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public let id: UUID           // PickUp request ID
    public let secretId: UUID
    public let label: String
    // The holder's stable local contact id — not their Ed25519 key — so this record survives a
    // holder key rotation/recovery (see deposplit.com/CLAUDE.md "What is next" item 7).
    public let contactId: UUID
    public let secretCreatedAt: Date

    public init(id: UUID, secretId: UUID, label: String, contactId: UUID, secretCreatedAt: Date) {
        self.id = id
        self.secretId = secretId
        self.label = label
        self.contactId = contactId
        self.secretCreatedAt = secretCreatedAt
    }
}

public struct ShareRequest: Identifiable, Equatable {
    public let id: UUID
    public let secretId: UUID
    public let senderKey: Data
    public let recipientKey: Data
    public let label: String
    public let secretCreatedAt: Date
    public let requestType: ShareRequestType
    public let state: ShareRequestState
    public let shareId: UUID?
    public let requestedAt: Date
    public let respondedAt: Date?
    public let ciphertext: Data?
    /// Ed25519 signature over `PayloadCanonical.forOpen` — see that type for what's signed.
    public let senderSignature: Data
    /// Ed25519 signature over `PayloadCanonical.forRespond`; nil while pending.
    public let recipientSignature: Data?

    public init(
        id: UUID, secretId: UUID, senderKey: Data, recipientKey: Data,
        label: String, secretCreatedAt: Date,
        requestType: ShareRequestType, state: ShareRequestState,
        shareId: UUID?, requestedAt: Date, respondedAt: Date?, ciphertext: Data?,
        senderSignature: Data, recipientSignature: Data?
    ) {
        self.id = id
        self.secretId = secretId
        self.senderKey = senderKey
        self.recipientKey = recipientKey
        self.label = label
        self.secretCreatedAt = secretCreatedAt
        self.requestType = requestType
        self.state = state
        self.shareId = shareId
        self.requestedAt = requestedAt
        self.respondedAt = respondedAt
        self.ciphertext = ciphertext
        self.senderSignature = senderSignature
        self.recipientSignature = recipientSignature
    }
}

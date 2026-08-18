import Foundation

/// A signed key-rotation push addressed to this device (item 9) — a contact's proactive "I am
/// now newEd25519Key, previously oldEd25519Key" notice. Deliberately not a `ShareRequest`: it
/// carries no `secretId` and has no consent phase — the recipient auto-verifies `signature`
/// against `oldEd25519Key` (the trusted key it already knows this contact by) and, on success,
/// updates its local contact record in place before deleting this notice. See
/// `PayloadCanonical.forRotation` for the exact bytes signed, and deposplit.com/CLAUDE.md "What
/// is next" item 9.
public struct KeyRotation: Identifiable, Equatable {
    public let id: UUID
    public let oldEd25519Key: Data
    public let recipientKey: Data
    public let newEd25519Key: Data
    public let newX25519Key: Data
    public let signature: Data
    public let createdAt: Date

    public init(id: UUID, oldEd25519Key: Data, recipientKey: Data, newEd25519Key: Data, newX25519Key: Data, signature: Data, createdAt: Date) {
        self.id = id
        self.oldEd25519Key = oldEd25519Key
        self.recipientKey = recipientKey
        self.newEd25519Key = newEd25519Key
        self.newX25519Key = newX25519Key
        self.signature = signature
        self.createdAt = createdAt
    }
}

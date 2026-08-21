import Foundation

/// A signed key-rotation push addressed to this device (item 9) — a contact's proactive "I am
/// now newVerifyKey, previously oldVerifyKey" notice. Deliberately not a `ShareRequest`: it
/// carries no `secretId` and has no consent phase — the recipient auto-verifies `signature`
/// against `oldVerifyKey` (the trusted key it already knows this contact by) and, on success,
/// updates its local contact record in place before deleting this notice. See
/// `PayloadCanonical.forRotation` for the exact bytes signed, and deposplit.com/CLAUDE.md "What
/// is next" item 9.
public struct KeyRotation: Identifiable, Equatable {
    public let id: UUID
    public let oldVerifyKey: Data
    public let recipientKey: Data
    public let newVerifyKey: Data
    public let newEncKey: Data
    /// Item 14 — the signing + key-agreement algorithm pairing `newVerifyKey`/`newEncKey` use. No
    /// `oldCipherSuite` field: the recipient already has it pinned on the existing contact record
    /// being rotated away from.
    public let newCipherSuite: CipherSuite
    public let signature: Data
    public let createdAt: Date

    public init(id: UUID, oldVerifyKey: Data, recipientKey: Data, newVerifyKey: Data, newEncKey: Data, newCipherSuite: CipherSuite, signature: Data, createdAt: Date) {
        self.id = id
        self.oldVerifyKey = oldVerifyKey
        self.recipientKey = recipientKey
        self.newVerifyKey = newVerifyKey
        self.newEncKey = newEncKey
        self.newCipherSuite = newCipherSuite
        self.signature = signature
        self.createdAt = createdAt
    }
}

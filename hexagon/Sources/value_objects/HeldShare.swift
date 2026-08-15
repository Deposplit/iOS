import Foundation

public struct HeldShare: Identifiable, Equatable {
    public let id: UUID
    public let secretId: UUID
    public let label: String
    // The sender's stable local contact id — not their Ed25519 key — so this record survives a
    // sender key rotation/recovery (see deposplit.com/CLAUDE.md "What is next" item 7).
    public let contactId: UUID
    // Denormalized snapshot of the sender's pseudonym at pickup time, so a share from a
    // since-deleted contact still renders sensibly.
    public let senderPseudonym: String
    public let createdAt: Date
    public let pickedUpAt: Date
    // The decrypted share, plaintext at rest — see item 7: a single holder's share is
    // information-theoretically empty on its own, so this is safe to store unencrypted.
    public let plaintextShare: Data

    public init(id: UUID, secretId: UUID, label: String, contactId: UUID, senderPseudonym: String, createdAt: Date, pickedUpAt: Date, plaintextShare: Data) {
        self.id = id
        self.secretId = secretId
        self.label = label
        self.contactId = contactId
        self.senderPseudonym = senderPseudonym
        self.createdAt = createdAt
        self.pickedUpAt = pickedUpAt
        self.plaintextShare = plaintextShare
    }
}

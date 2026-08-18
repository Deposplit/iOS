import Foundation

public protocol ContactManagement {
    func listContacts() throws -> [Contact]
    func addManually(pseudonym: String, edPublicKey: Data, xPublicKey: Data, verificationLevel: VerificationLevel, relayBaseUrl: String?) throws
    func addFromQr(pseudonym: String, edPublicKey: Data, xPublicKey: Data, verificationLevel: VerificationLevel, relayBaseUrl: String?) throws
    /// Updates an existing contact **in place**, preserving `contactId` — never delete-and-re-add,
    /// which would mint a fresh id and orphan any `HeldShare`/`ShareMetadata` rows anchored to it.
    /// See deposplit.com/CLAUDE.md "What is next" item 8. `edPublicKey`/`xPublicKey` are nil to
    /// leave the keys unchanged; when either is non-nil (a key change), `verificationLevel` must
    /// be supplied too — a key change forces re-choosing the level fresh, never a silent carry
    /// forward of the old key's assurance.
    func updateContact(contactId: UUID, edPublicKey: Data?, xPublicKey: Data?, verificationLevel: VerificationLevel?) throws
    func deleteContact(contactId: UUID) throws

    /// Marks a specific Ed25519 key as compromised for this contact (item 10) — the local,
    /// socially-anchored side of stolen-key revocation. `edPublicKey` defaults to the contact's
    /// *current* key when nil (the common case: "I just learned this contact's current key is
    /// stolen"). Once flagged, a signed rotation notice claiming continuity from that key is
    /// refused auto-accept by `ShareManagement`'s rotation-processing — the only way forward is
    /// a fresh, human-verified relink via `updateContact`, never an automatic acceptance.
    func markKeyCompromised(contactId: UUID, edPublicKey: Data?) throws
}

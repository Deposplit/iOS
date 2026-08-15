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
}

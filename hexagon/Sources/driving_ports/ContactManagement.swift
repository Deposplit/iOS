import Foundation

public protocol ContactManagement {
    func listContacts() throws -> [Contact]
    /// `addManually` has no `cipherSuite` parameter — manual entry has no wire-carried suite
    /// info, so `ContactService` pins the contact to `CipherSuite.current` (the only suite there
    /// is to assume today).
    func addManually(pseudonym: String, verifyKey: Data, encKey: Data, verificationLevel: VerificationLevel, relayBaseUrl: String?) throws
    /// `cipherSuite` (item 14) is the signing + key-agreement algorithm pairing asserted by the
    /// scanned QR payload — self-describing keys, not assumed.
    func addFromQr(pseudonym: String, verifyKey: Data, encKey: Data, cipherSuite: CipherSuite, verificationLevel: VerificationLevel, relayBaseUrl: String?) throws
    /// Updates an existing contact **in place**, preserving `contactId` — never delete-and-re-add,
    /// which would mint a fresh id and orphan any `HeldShare`/`ShareMetadata` rows anchored to it.
    /// See deposplit.com/CLAUDE.md "What is next" item 8. `verifyKey`/`encKey` are nil to
    /// leave the keys unchanged; when either is non-nil (a key change), `verificationLevel` must
    /// be supplied too — a key change forces re-choosing the level fresh, never a silent carry
    /// forward of the old key's assurance. `newCipherSuite` (item 14) is likewise nil to leave the
    /// suite unchanged; a suite-only change (no key-value change) forces the same fresh-level
    /// rule as a key change — an algorithm change is still "continuity of key control, not a
    /// personhood assurance," the same reasoning item 10 already applies to a plain key rotation.
    func updateContact(contactId: UUID, verifyKey: Data?, encKey: Data?, newCipherSuite: CipherSuite?, verificationLevel: VerificationLevel?) throws
    func deleteContact(contactId: UUID) throws

    /// Marks a specific Ed25519 key as compromised for this contact (item 10) — the local,
    /// socially-anchored side of stolen-key revocation. `verifyKey` defaults to the contact's
    /// *current* key when nil (the common case: "I just learned this contact's current key is
    /// stolen"). Once flagged, a signed rotation notice claiming continuity from that key is
    /// refused auto-accept by `ShareManagement`'s rotation-processing — the only way forward is
    /// a fresh, human-verified relink via `updateContact`, never an automatic acceptance.
    func markKeyCompromised(contactId: UUID, verifyKey: Data?) throws
}

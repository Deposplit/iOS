import Foundation

public protocol ContactManagement {
    func listContacts() throws -> [Contact]

    /// Contacts who still hold a key this device no longer signs with, and so cannot address it any
    /// more. A contact added before the current identity was established has by construction never
    /// seen it, unless something has arrived from them since — the relay only returns rows addressed
    /// to the caller's current key, so receiving anything at all is proof they relinked.
    ///
    /// Empty after a rotation, which propagates on its own; this is for the case that cannot, where
    /// the keys were lost and the rotation notice could never be signed. Empty too on a device with
    /// no recorded `Identity.identityCreatedAt`, rather than flagging every contact on a guess.
    func contactsAwaitingRelink() -> [Contact]

    /// Records that this contact has relinked, when nothing will arrive to prove it — a contact who
    /// holds no share and sends nothing produces no evidence, so without this the list could never
    /// empty. Idempotent.
    func markRelinked(_ contactId: UUID)
    /// `addManually` has no `cipherSuite` parameter — manual entry has no wire-carried suite
    /// info, so `ContactService` pins the contact to `CipherSuite.current` (the only suite there
    /// is to assume today). `nickname` lets a nickname be set at add-time rather than
    /// only via a later `renameContact` call; it is purely local and never transmitted anywhere.
    /// A non-nil `relayBaseUrl` requires the Premium unlock — typing a relay by hand is the paid
    /// half of BYOR, while `addFromQr`'s is free.
    func addManually(pseudonym: String, verifyKey: Data, encKey: Data, verificationLevel: VerificationLevel, relayBaseUrl: String?, nickname: String?) throws
    /// `cipherSuite` is the signing + key-agreement algorithm pairing asserted by the scanned
    /// QR payload — self-describing keys, not assumed. `nickname` is not
    /// sourced from the QR payload either — it is purely local — so callers typically pass nil.
    func addFromQr(pseudonym: String, verifyKey: Data, encKey: Data, cipherSuite: CipherSuite, verificationLevel: VerificationLevel, relayBaseUrl: String?, nickname: String?) throws
    /// Updates an existing contact **in place**, preserving `contactId` — never delete-and-re-add,
    /// which would mint a fresh id and orphan any `HeldShare`/`ShareMetadata` rows anchored to it.
    /// `verifyKey`/`encKey` are nil to leave the keys unchanged; when either is non-nil (a key
    /// change), `verificationLevel` must be supplied too — a key change forces re-choosing the
    /// level fresh, never a silent carry forward of the old key's assurance. `newCipherSuite` is
    /// likewise nil to leave the suite unchanged; a suite-only change (no key-value change)
    /// forces the same fresh-level rule as a key change — an algorithm change is still
    /// "continuity of key control, not a personhood assurance," the same reasoning that applies
    /// to a plain key rotation.
    func updateContact(contactId: UUID, verifyKey: Data?, encKey: Data?, newCipherSuite: CipherSuite?, verificationLevel: VerificationLevel?) throws
    /// Deliberately separate from `updateContact`: a rename is not an identity change,
    /// so it must never trigger `updateContact`'s `changingIdentity` gate (which forces
    /// re-choosing the verification level). Pass `nil` to clear an existing nickname.
    func renameContact(contactId: UUID, nickname: String?) throws
    func deleteContact(contactId: UUID) throws

    /// Marks a specific Ed25519 key as compromised for this contact — the local,
    /// socially-anchored side of stolen-key revocation. `verifyKey` defaults to the contact's
    /// *current* key when nil (the common case: "I just learned this contact's current key is
    /// stolen"). Once flagged, a signed rotation notice claiming continuity from that key is
    /// refused auto-accept by `ShareManagement`'s rotation-processing — the only way forward is
    /// a fresh, human-verified relink via `updateContact`, never an automatic acceptance.
    func markKeyCompromised(contactId: UUID, verifyKey: Data?) throws
}

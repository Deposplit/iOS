import Foundation

public protocol ShareManagement {
    // Sender
    func deposit(secret: Data, label: String, contacts: [Contact], threshold: Int) async throws
    func listSecrets() throws -> [Secret]
    func listDistributed() throws -> [ShareMetadata]
    func syncDistributed() async throws
    func listSentRequests() async throws -> [ShareRequest]
    func requestAll(secretId: UUID) async throws
    func openRequest(shareId: UUID, type: ShareTransactionType) async throws -> ShareRequest
    /// Pure read — collects approved retrieval shares (possibly more than `k`) and decrypts
    /// them. Never tears down local `ShareMetadata` or relay rows; use `discardSecret` for that.
    /// Cross-checks any surplus beyond `k` for consistency — throws rather than returning a
    /// guessed secret if the surplus can't be reconciled.
    func reconstruct(secretId: UUID) async throws -> ReconstructionResult
    /// Fans out a sender-initiated `removal` request to every known holder of `secretId` and
    /// flips the `Secret` to `.discarding` immediately (before any holder responds).
    func discardSecret(secretId: UUID) async throws
    /// Local-only teardown for a `.discarding` secret whose holders will never all respond
    /// (e.g. a permanently dark holder). Does not wait for or require relay confirmation.
    func forceForgetSecret(secretId: UUID) throws

    // Recipient
    func syncInbox() async throws
    func listHeld() throws -> [HeldShare]
    func listPendingRequests() async throws -> [ShareRequest]
    func respond(requestId: UUID, approved: Bool) async throws
    func deleteHeldShare(shareId: UUID) async throws
    func deleteAllHeldFromSender(contactId: UUID) async throws

    // Identity recovery — holder side. Pushes a metadata-only report (no share bytes)
    // for every `HeldShare` held from `contactId` back to that contact, so a recovering owner
    // can rebuild her `ShareMetadata`/`Secret` records. Call after `ContactManagement
    // .updateContact` has relinked the re-presented identity to the existing contact.
    func pushRecoveryMetadata(contactId: UUID) async throws

    // Signed rotate(K_old -> K_new) push, client primitive only. Signs newVerifyKey/newEncKey
    // with the device's *current* identity (which becomes `oldVerifyKey` on the wire) and pushes
    // one signed notice to `contactId`. Used both directly by tests and internally by
    // `regenerateIdentity()`. `newCipherSuite` is the signing + key-agreement algorithm pairing
    // the new keys use.
    func pushRotation(contactId: UUID, newVerifyKey: Data, newEncKey: Data, newCipherSuite: CipherSuite) async throws

    // Stolen-key revocation. A rotation notice whose old key is locally flagged
    // compromised (`ContactManagement.markKeyCompromised`) is never auto-accepted; instead it's
    // captured as a `KeyConflict` for manual resolution — see `KeyConflict` for why this is a
    // durable local record, not something re-derived from the relay on demand.
    func listKeyConflicts() throws -> [KeyConflict]
    /// Dismisses a conflict once the user has resolved it out-of-band (either as a false alarm,
    /// or by performing a fresh human-verified relink separately). Local-only — the underlying
    /// relay notice was already deleted at detection time.
    func dismissKeyConflict(id: UUID) throws

    // The holder role. This device's own choice to stop (or resume) heartbeating
    // `contactId` (who is the owner in that relationship). Updates the local preference only —
    // the opportunistic `syncInbox()` emission loop is what actually reaches the contact, on its
    // normal per-sender cadence; this resets that contact's `lastHeartbeatSentAt` so the change
    // reaches them on the very next poll rather than waiting out the interval.
    func setHeartbeatEmissionOptedOut(contactId: UUID, optedOut: Bool) throws

    // The "regenerate my own identity" trigger (proactive rotation while still holding the
    // device and old keys — distinct from device-*loss* identity recovery). Best-effort drains
    // the inbox/distributed state under the *old* identity, generates a fresh keypair, pushes a
    // signed rotation notice (via the existing `pushRotation`, unchanged) to every contact while
    // still signing as the old identity, then activates the new keypair locally. A contact whose
    // push fails is not retried — same one-shot semantics as `pushRotation` itself.
    func regenerateIdentity() async throws -> RegenerateIdentityResult
}

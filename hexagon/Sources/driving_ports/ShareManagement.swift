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
    /// Pure read — collects `k` approved retrieval shares and decrypts them. Never tears down
    /// local `ShareMetadata` or relay rows; use `discardSecret` for that. See item 11.
    func reconstruct(secretId: UUID) async throws -> Data
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

    // Identity recovery (item 8) — holder side. Pushes a metadata-only report (no share bytes)
    // for every `HeldShare` held from `contactId` back to that contact, so a recovering owner
    // can rebuild her `ShareMetadata`/`Secret` records. Call after `ContactManagement
    // .updateContact` has relinked the re-presented identity to the existing contact.
    func pushRecoveryMetadata(contactId: UUID) async throws

    // Item 9 — signed rotate(K_old -> K_new) push, client primitive only. Signs
    // newEd25519Key/newX25519Key with the device's *current* identity (which becomes
    // `oldEd25519Key` on the wire) and pushes one signed notice to `contactId`. There is
    // deliberately no "regenerate my own identity" trigger yet — see deposplit.com/TODO.md item
    // 9's scope-split note — so callers supply the new keys directly; this method is exercised
    // by tests today, not yet by any UI action.
    func pushRotation(contactId: UUID, newEd25519Key: Data, newX25519Key: Data) async throws

    // Item 10 — stolen-key revocation. A rotation notice whose old key is locally flagged
    // compromised (`ContactManagement.markKeyCompromised`) is never auto-accepted; instead it's
    // captured as a `KeyConflict` for manual resolution — see `KeyConflict` for why this is a
    // durable local record, not something re-derived from the relay on demand.
    func listKeyConflicts() throws -> [KeyConflict]
    /// Dismisses a conflict once the user has resolved it out-of-band (either as a false alarm,
    /// or by performing a fresh human-verified relink separately). Local-only — the underlying
    /// relay notice was already deleted at detection time.
    func dismissKeyConflict(id: UUID) throws

    // Item 12 — holder role. This device's own choice to stop (or resume) heartbeating
    // `contactId` (who is the owner in that relationship). Updates the local preference only —
    // the opportunistic `syncInbox()` emission loop is what actually reaches the contact, on its
    // normal per-sender cadence; this resets that contact's `lastHeartbeatSentAt` so the change
    // reaches them on the very next poll rather than waiting out the interval.
    func setHeartbeatEmissionOptedOut(contactId: UUID, optedOut: Bool) throws
}

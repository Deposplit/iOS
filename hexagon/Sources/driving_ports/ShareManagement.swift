import Foundation

public protocol ShareManagement {
    // Sender
    func deposit(secret: Data, label: String, contacts: [Contact], threshold: Int) async throws
    func listSecrets() throws -> [Secret]
    func listDistributed() throws -> [ShareMetadata]
    func syncDistributed() async throws
    func listSentRequests() async throws -> [ShareRequest]
    func requestAll(secretId: UUID) async throws
    func openRequest(shareId: UUID, type: ShareRequestType) async throws -> ShareRequest
    /// Pure read — collects `k` approved retrieve shares and decrypts them. Never tears down
    /// local `ShareMetadata` or relay rows; use `discardSecret` for that. See item 11.
    func reconstruct(secretId: UUID) async throws -> Data
    /// Fans out a sender-initiated `delete` request to every known holder of `secretId` and
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
}

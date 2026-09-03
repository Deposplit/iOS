import Foundation

public protocol ShareRelay {
    func openShareRequest(secretId: UUID, recipientKey: Data, label: String, secretCreatedAt: Date, transactionType: ShareTransactionType, ciphertext: Data?, k: Int?, n: Int?, mimeType: MimeType?, senderSignature: Data) async throws -> ShareRequest
    func listShareRequests(role: Role, transactionType: ShareTransactionType?, state: ShareRequestState?) async throws -> [ShareRequest]
    func getShareRequest(requestId: UUID) async throws -> ShareRequest
    func respondToShareRequest(requestId: UUID, approved: Bool, ciphertext: Data?, recipientSignature: Data) async throws -> ShareRequest
    func deleteShareRequest(requestId: UUID) async throws
    func deleteShareRequests(senderKey: Data?, secretId: UUID?) async throws

    /// Recipient-initiated unilateral withdrawal — flips matching approved Deposit rows
    /// to `.withdrawn` on the relay instead of deleting them, so the sender's next poll can
    /// observe the tombstone. Best-effort and fire-and-forget.
    func withdrawShareRequests(senderKey: Data?, secretId: UUID?) async throws

    // The signed rotate(K_old -> K_new) push. Grouped onto this protocol rather than a
    // separate port: it's the same physical relay endpoint and the same BYOR per-contact routing
    // as every other ShareRelay call. deposplit.com's own backend keeps rotation pushes in a
    // dedicated `key_rotations` table/`KeyRotations` service for domain-purity reasons (no
    // secretId, no consent phase) that are about server-side schema shape, not about this
    // client-side HTTP-calling port, so no equivalent split is needed here.

    /// Pushes a signed rotation notice to one contact. `signature` must verify against the
    /// caller's own current Ed25519 key (the relay's `oldVerifyKey`) over
    /// `PayloadCanonical.forRotation`.
    func pushRotation(recipientKey: Data, newVerifyKey: Data, newEncKey: Data, newCipherSuite: CipherSuite, signature: Data) async throws
    /// Rotation notices addressed to this device.
    func listRotations() async throws -> [KeyRotation]
    /// Deletes a rotation notice once consumed.
    func deleteRotation(id: UUID) async throws

    // The signed custodial-heartbeat push — same "grouped onto this protocol" reasoning as
    // the rotation push above: one physical relay, one BYOR routing scheme.

    /// Pushes (upserts) a signed heartbeat for one owner, replacing any previous heartbeat this
    /// device sent to that owner. `signature` must verify against the caller's own current
    /// Ed25519 key (the relay's `holderKey`) over `PayloadCanonical.forHeartbeat`.
    func pushHeartbeat(ownerKey: Data, secretIds: [UUID], optedOut: Bool, signature: Data) async throws
    /// The latest heartbeat (or opt-out) from each holder addressed to this device.
    func listHeartbeats() async throws -> [CustodyHeartbeat]
}

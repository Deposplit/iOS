import Foundation

public protocol ShareManagement {
    // Sender
    func deposit(secret: Data, label: String, contacts: [Contact], threshold: Int) async throws
    func listDistributed() async throws -> [ShareMetadata]
    func listSentRequests() async throws -> [ShareRequest]
    func requestAll(secretId: UUID) async throws
    func openRequest(shareId: UUID, type: ShareRequestType) async throws -> ShareRequest
    func reconstruct(secretId: UUID) async throws -> Data

    // Recipient
    func syncInbox() async throws
    func listHeld() async throws -> [HeldShare]
    func listPendingRequests() async throws -> [ShareRequest]
    func respond(requestId: UUID, approved: Bool) async throws
    func deleteHeldShare(shareId: UUID) async throws
    func deleteAllHeldFromSender(senderKey: Data) async throws
}

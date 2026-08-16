import Foundation

public protocol ShareRelay {
    func openShareRequest(secretId: UUID, recipientKey: Data, label: String, secretCreatedAt: Date, transactionType: ShareTransactionType, shareId: UUID?, ciphertext: Data?, k: Int?, n: Int?, senderSignature: Data) async throws -> ShareRequest
    func listShareRequests(role: Role, transactionType: ShareTransactionType?, state: ShareRequestState?) async throws -> [ShareRequest]
    func getShareRequest(requestId: UUID) async throws -> ShareRequest
    func respondToShareRequest(requestId: UUID, approved: Bool, ciphertext: Data?, recipientSignature: Data) async throws -> ShareRequest
    func deleteShareRequest(requestId: UUID) async throws
    func deleteShareRequests(senderKey: Data?, secretId: UUID?) async throws
}

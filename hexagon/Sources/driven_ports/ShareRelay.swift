import Foundation

public protocol ShareRelay {
    func depositShare(secretId: UUID, label: String, recipientKey: Data, ciphertext: Data) async throws -> ShareMetadata
    func listShares(role: Role, counterpartyKey: Data?) async throws -> [ShareMetadata]
    func pickUpShare(shareId: UUID) async throws -> Data
    func deleteShare(shareId: UUID) async throws
    func openShareRequest(shareId: UUID, type: ShareRequestType) async throws -> ShareRequest
    func listShareRequests(role: Role, state: ShareRequestState?) async throws -> [ShareRequest]
    func getShareRequest(requestId: UUID) async throws -> ShareRequest
    func respondToShareRequest(requestId: UUID, approved: Bool, ciphertext: Data?) async throws -> ShareRequest
}

import Foundation

enum Role: String {
    case sender, recipient
}

enum ShareRequestType: String {
    case retrieve, delete
}

enum ShareRequestState: String {
    case pending, approved, denied
}

struct ShareMetadata: Identifiable, Equatable, Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: UUID
    let secretId: UUID
    let label: String
    let senderKey: Data
    let recipientKey: Data
    let createdAt: String
}

struct ShareRequest: Identifiable, Equatable {
    let id: UUID
    let share: ShareMetadata
    let requestType: ShareRequestType
    let state: ShareRequestState
    let requestedAt: String
    let respondedAt: String?
    let ciphertext: Data?
}

protocol ShareTransport {
    func depositShare(secretId: UUID, label: String, recipientKey: Data, ciphertext: Data) async throws -> ShareMetadata
    func listShares(role: Role, counterpartyKey: Data?) async throws -> [ShareMetadata]
    func deleteShare(shareId: UUID) async throws
    func openShareRequest(shareId: UUID, type: ShareRequestType) async throws -> ShareRequest
    func listShareRequests(role: Role, state: ShareRequestState?) async throws -> [ShareRequest]
    func getShareRequest(requestId: UUID) async throws -> ShareRequest
    func respondToShareRequest(requestId: UUID, approved: Bool) async throws -> ShareRequest
}

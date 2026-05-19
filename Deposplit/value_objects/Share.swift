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
    let createdAt: Date
}

struct ShareRequest: Identifiable, Equatable {
    let id: UUID
    let share: ShareMetadata
    let requestType: ShareRequestType
    let state: ShareRequestState
    let requestedAt: Date
    let respondedAt: Date?
    let ciphertext: Data?
}

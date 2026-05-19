import Foundation

public enum Role: String {
    case sender, recipient
}

public enum ShareRequestType: String {
    case retrieve, delete
}

public enum ShareRequestState: String {
    case pending, approved, denied
}

public struct ShareMetadata: Identifiable, Equatable, Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public let id: UUID
    public let secretId: UUID
    public let label: String
    public let senderKey: Data
    public let recipientKey: Data
    public let createdAt: Date

    public init(id: UUID, secretId: UUID, label: String, senderKey: Data, recipientKey: Data, createdAt: Date) {
        self.id = id
        self.secretId = secretId
        self.label = label
        self.senderKey = senderKey
        self.recipientKey = recipientKey
        self.createdAt = createdAt
    }
}

public struct ShareRequest: Identifiable, Equatable {
    public let id: UUID
    public let share: ShareMetadata
    public let requestType: ShareRequestType
    public let state: ShareRequestState
    public let requestedAt: Date
    public let respondedAt: Date?
    public let ciphertext: Data?

    public init(
        id: UUID, share: ShareMetadata,
        requestType: ShareRequestType, state: ShareRequestState,
        requestedAt: Date, respondedAt: Date?, ciphertext: Data?
    ) {
        self.id = id
        self.share = share
        self.requestType = requestType
        self.state = state
        self.requestedAt = requestedAt
        self.respondedAt = respondedAt
        self.ciphertext = ciphertext
    }
}

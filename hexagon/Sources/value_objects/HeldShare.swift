import Foundation

public struct HeldShare: Identifiable, Equatable {
    public let id: UUID
    public let secretId: UUID
    public let label: String
    public let senderKey: Data
    public let createdAt: Date
    public let pickedUpAt: Date
    public let ciphertext: Data

    public init(id: UUID, secretId: UUID, label: String, senderKey: Data, createdAt: Date, pickedUpAt: Date, ciphertext: Data) {
        self.id = id
        self.secretId = secretId
        self.label = label
        self.senderKey = senderKey
        self.createdAt = createdAt
        self.pickedUpAt = pickedUpAt
        self.ciphertext = ciphertext
    }
}

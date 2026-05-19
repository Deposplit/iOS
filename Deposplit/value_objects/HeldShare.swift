import Foundation

struct HeldShare: Identifiable, Equatable {
    let id: UUID
    let secretId: UUID
    let label: String
    let senderKey: Data
    let createdAt: String
    let ciphertext: Data
}

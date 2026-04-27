import Foundation

struct HeldShare: Identifiable, Equatable {
    let id: UUID
    let secretId: UUID
    let label: String
    let senderKey: Data
    let createdAt: String
    let ciphertext: Data
}

protocol ShareRepository {
    func getAll() -> [HeldShare]
    func getCiphertext(shareId: UUID) -> Data?
    func save(_ share: HeldShare)
    func delete(shareId: UUID)
}

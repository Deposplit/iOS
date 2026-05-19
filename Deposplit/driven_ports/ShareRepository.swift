import Foundation

protocol ShareRepository {
    func getAll() -> [HeldShare]
    func getCiphertext(shareId: UUID) -> Data?
    func save(_ share: HeldShare)
    func delete(shareId: UUID)
}

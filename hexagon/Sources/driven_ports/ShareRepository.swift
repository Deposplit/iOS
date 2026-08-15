import Foundation

public protocol ShareRepository {
    func getAll() -> [HeldShare]
    func getPlaintextShare(shareId: UUID) -> Data?
    func save(_ share: HeldShare)
    func delete(shareId: UUID)
}

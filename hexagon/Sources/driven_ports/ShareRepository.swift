import Foundation

public protocol ShareRepository {
    func getAll() -> [HeldShare]
    // Keyed on secretId, not the pickup relay-row id — secretId survives device loss/recovery
    // and is unique per (secretId, sender) at a given holder. See item 8's "re-key retrieve".
    func getPlaintextShare(secretId: UUID) -> Data?
    func save(_ share: HeldShare)
    func delete(shareId: UUID)
}

import Foundation

public protocol ShareRepository {
    func getAll() -> [HeldShare]
    // Keyed on secretId, not the pickup relay-row id — secretId survives device loss/recovery
    // and is unique per (secretId, sender) at a given holder — which is what lets a retrieval
    // after identity recovery re-key against a share this device can still find.
    func getPlaintextShare(secretId: UUID) -> Data?
    func save(_ share: HeldShare)
    func delete(shareId: UUID)
}

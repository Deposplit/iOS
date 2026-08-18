import Foundation

/// Local store of detected key conflicts (item 10) — see `KeyConflict` for why this is a durable
/// local record rather than something re-derived from the relay on demand.
public protocol KeyConflictRepository {
    func getAll() throws -> [KeyConflict]
    func save(_ conflict: KeyConflict) throws
    func delete(id: UUID) throws
}

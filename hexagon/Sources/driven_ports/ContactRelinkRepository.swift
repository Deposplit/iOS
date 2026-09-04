import Foundation

/// Records which contacts are known to hold this device's current key. Latest-wins per contact:
/// `save` replaces any earlier record, since only the most recent evidence matters.
public protocol ContactRelinkRepository {
    func getAll() -> [ContactRelink]
    func get(_ contactId: UUID) -> ContactRelink?
    func save(_ relink: ContactRelink)
}

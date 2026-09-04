import hexagon
import Foundation

/// Which contacts are known to hold this device's current key. `ContactRelink` is `Codable` and
/// carries only a UUID and a date, so unlike `Contact` it needs no hand-written JSON shim.
final class LocalContactRelinkRepository: ContactRelinkRepository {

    private let fileURL: URL
    private var cache: [ContactRelink]?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("contact_relinks.json")
    }

    func getAll() -> [ContactRelink] {
        if let cached = cache { return cached }
        let relinks = (try? load()) ?? []
        cache = relinks
        return relinks
    }

    func get(_ contactId: UUID) -> ContactRelink? {
        getAll().first { $0.contactId == contactId }
    }

    func save(_ relink: ContactRelink) {
        var all = getAll()
        all.removeAll { $0.contactId == relink.contactId }
        all.append(relink)
        cache = all
        try? persist(all)
    }

    // MARK: - Persistence

    private func load() throws -> [ContactRelink] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ContactRelink].self, from: data)
    }

    private func persist(_ relinks: [ContactRelink]) throws {
        let data = try JSONEncoder().encode(relinks)
        try data.write(to: fileURL, options: .atomic)
    }
}

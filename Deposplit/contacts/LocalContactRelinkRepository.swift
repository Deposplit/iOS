import hexagon
import Foundation

/// Which contacts are known to hold this device's current key. `ContactRelink` is `Codable` and
/// carries only a UUID and a date, so unlike `Contact` it needs no hand-written JSON shim — only
/// its date written the way every store writes one, as `PayloadCanonical.wireInstant`, rather than
/// as the seconds since 2001 that `Codable` writes for a `Date` when left to itself.
final class LocalContactRelinkRepository: ContactRelinkRepository {

    private let fileURL: URL
    private var cache: [ContactRelink]?

    init() {
        fileURL = AppFiles.url("contact_relinks.json")
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = PayloadCanonical.parseWireInstant(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a timestamp: \(text)")
            }
            return date
        }
        return try decoder.decode([ContactRelink].self, from: data)
    }

    private func persist(_ relinks: [ContactRelink]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PayloadCanonical.wireInstant(date))
        }
        let data = try encoder.encode(relinks)
        try data.write(to: fileURL, options: .atomic)
    }
}

import hexagon
import Foundation

final class LocalKeyConflictRepository: KeyConflictRepository {

    private let fileURL: URL
    private var cache: [KeyConflict]?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("key_conflicts.json")
    }

    func getAll() throws -> [KeyConflict] {
        if let cached = cache { return cached }
        let conflicts = (try? load()) ?? []
        cache = conflicts
        return conflicts
    }

    func save(_ conflict: KeyConflict) throws {
        var all = (try? getAll()) ?? []
        all.removeAll { $0.id == conflict.id }
        all.append(conflict)
        cache = all
        try persist(all)
    }

    func delete(id: UUID) throws {
        var all = (try? getAll()) ?? []
        all.removeAll { $0.id == id }
        cache = all
        try persist(all)
    }

    // MARK: - Persistence

    private struct KeyConflictJSON: Codable {
        let id: String
        let contactId: String
        let oldVerifyKey: String
        let newVerifyKey: String
        let newEncKey: String
        let detectedAt: String
    }

    private func load() throws -> [KeyConflict] {
        let data = try Data(contentsOf: fileURL)
        let items = try JSONDecoder().decode([KeyConflictJSON].self, from: data)
        return items.compactMap { json in
            guard let id = UUID(uuidString: json.id),
                  let contactId = UUID(uuidString: json.contactId),
                  let oldEd = Data(base64URLEncoded: json.oldVerifyKey),
                  let newEd = Data(base64URLEncoded: json.newVerifyKey),
                  let newX = Data(base64URLEncoded: json.newEncKey),
                  let detectedAt = _keyConflictISO8601.date(from: json.detectedAt) else { return nil }
            return KeyConflict(id: id, contactId: contactId, oldVerifyKey: oldEd, newVerifyKey: newEd, newEncKey: newX, detectedAt: detectedAt)
        }
    }

    private func persist(_ conflicts: [KeyConflict]) throws {
        let items = conflicts.map { c in
            KeyConflictJSON(
                id: c.id.uuidString,
                contactId: c.contactId.uuidString,
                oldVerifyKey: c.oldVerifyKey.base64URLEncoded,
                newVerifyKey: c.newVerifyKey.base64URLEncoded,
                newEncKey: c.newEncKey.base64URLEncoded,
                detectedAt: _keyConflictISO8601.string(from: c.detectedAt)
            )
        }
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
    }
}

private let _keyConflictISO8601 = ISO8601DateFormatter()

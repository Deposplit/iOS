import hexagon
import Foundation

final class LocalShareRepository: ShareRepository {

    private let fileURL: URL
    private var cache: [HeldShare]?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("shares.json")
    }

    func getAll() -> [HeldShare] {
        if let cached = cache { return cached }
        let shares = (try? load()) ?? []
        cache = shares
        return shares
    }

    func getCiphertext(shareId: UUID) -> Data? {
        getAll().first { $0.id == shareId }?.ciphertext
    }

    func save(_ share: HeldShare) {
        var all = getAll()
        all.removeAll { $0.id == share.id }
        all.append(share)
        cache = all
        try? persist(all)
    }

    func delete(shareId: UUID) {
        var all = getAll()
        all.removeAll { $0.id == shareId }
        cache = all
        try? persist(all)
    }

    // MARK: - Persistence

    private struct HeldShareJSON: Codable {
        let id: String
        let secretId: String
        let label: String
        let senderKey: String    // base64url
        let createdAt: String
        let pickedUpAt: String   // ISO-8601
        let ciphertext: String   // standard base64
    }

    private func load() throws -> [HeldShare] {
        let data = try Data(contentsOf: fileURL)
        let items = try JSONDecoder().decode([HeldShareJSON].self, from: data)
        return items.map { json in
            HeldShare(
                id: UUID(uuidString: json.id)!,
                secretId: UUID(uuidString: json.secretId)!,
                label: json.label,
                senderKey: Data(base64URLEncoded: json.senderKey)!,
                createdAt: _localISO8601.date(from: json.createdAt)!,
                pickedUpAt: _localISO8601.date(from: json.pickedUpAt)!,
                ciphertext: Data(base64Encoded: json.ciphertext)!
            )
        }
    }

    private func persist(_ shares: [HeldShare]) throws {
        let items = shares.map { s in
            HeldShareJSON(
                id: s.id.uuidString,
                secretId: s.secretId.uuidString,
                label: s.label,
                senderKey: s.senderKey.base64URLEncoded,
                createdAt: _localISO8601.string(from: s.createdAt),
                pickedUpAt: _localISO8601.string(from: s.pickedUpAt),
                ciphertext: s.ciphertext.base64EncodedString()
            )
        }
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
    }
}

private let _localISO8601 = ISO8601DateFormatter()

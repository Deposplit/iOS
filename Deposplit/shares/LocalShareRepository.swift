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
        let ciphertext: String   // standard base64
    }

    private func load() throws -> [HeldShare] {
        let data = try Data(contentsOf: fileURL)
        let items = try JSONDecoder().decode([HeldShareJSON].self, from: data)
        return items.compactMap { json in
            guard let id = UUID(uuidString: json.id),
                  let secretId = UUID(uuidString: json.secretId),
                  let senderKey = Data(base64URLEncoded: json.senderKey),
                  let ciphertext = Data(base64Encoded: json.ciphertext) else { return nil }
            return HeldShare(
                id: id,
                secretId: secretId,
                label: json.label,
                senderKey: senderKey,
                createdAt: json.createdAt,
                ciphertext: ciphertext
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
                createdAt: s.createdAt,
                ciphertext: s.ciphertext.base64EncodedString()
            )
        }
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
    }
}

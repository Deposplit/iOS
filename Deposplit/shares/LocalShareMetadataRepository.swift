import hexagon
import Foundation

final class LocalShareMetadataRepository: ShareMetadataRepository {

    private let fileURL: URL
    private var cache: [ShareMetadata]?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("distributed_shares.json")
    }

    func getAll() throws -> [ShareMetadata] {
        if let cached = cache { return cached }
        let shares = (try? load()) ?? []
        cache = shares
        return shares
    }

    func save(_ share: ShareMetadata) throws {
        var all = (try? getAll()) ?? []
        all.removeAll { $0.id == share.id }
        all.append(share)
        cache = all
        try persist(all)
    }

    func delete(shareId: UUID) throws {
        var all = (try? getAll()) ?? []
        all.removeAll { $0.id == shareId }
        cache = all
        try persist(all)
    }

    // MARK: - Persistence

    private struct ShareMetadataJSON: Codable {
        let id: String
        let secretId: String
        let label: String
        let senderKey: String     // base64url
        let recipientKey: String  // base64url
        let createdAt: String
    }

    private func load() throws -> [ShareMetadata] {
        let data = try Data(contentsOf: fileURL)
        let items = try JSONDecoder().decode([ShareMetadataJSON].self, from: data)
        return items.compactMap { json in
            guard let id = UUID(uuidString: json.id),
                  let secretId = UUID(uuidString: json.secretId),
                  let senderKey = Data(base64URLEncoded: json.senderKey),
                  let recipientKey = Data(base64URLEncoded: json.recipientKey),
                  let createdAt = _smrISO8601.date(from: json.createdAt) else { return nil }
            return ShareMetadata(
                id: id,
                secretId: secretId,
                label: json.label,
                senderKey: senderKey,
                recipientKey: recipientKey,
                createdAt: createdAt
            )
        }
    }

    private func persist(_ shares: [ShareMetadata]) throws {
        let items = shares.map { s in
            ShareMetadataJSON(
                id: s.id.uuidString,
                secretId: s.secretId.uuidString,
                label: s.label,
                senderKey: s.senderKey.base64URLEncoded,
                recipientKey: s.recipientKey.base64URLEncoded,
                createdAt: _smrISO8601.string(from: s.createdAt)
            )
        }
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
    }
}

private let _smrISO8601 = ISO8601DateFormatter()

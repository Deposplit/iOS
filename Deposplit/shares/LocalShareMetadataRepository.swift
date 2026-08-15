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
        let contactId: String
    }

    private func load() throws -> [ShareMetadata] {
        let data = try Data(contentsOf: fileURL)
        let items = try JSONDecoder().decode([ShareMetadataJSON].self, from: data)
        return items.compactMap { json in
            guard let id = UUID(uuidString: json.id),
                  let secretId = UUID(uuidString: json.secretId),
                  let contactId = UUID(uuidString: json.contactId) else { return nil }
            return ShareMetadata(id: id, secretId: secretId, contactId: contactId)
        }
    }

    private func persist(_ shares: [ShareMetadata]) throws {
        let items = shares.map { s in
            ShareMetadataJSON(id: s.id.uuidString, secretId: s.secretId.uuidString, contactId: s.contactId.uuidString)
        }
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
    }
}

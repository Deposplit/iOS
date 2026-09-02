import hexagon
import Foundation

/// The local store of `RetainedDepositBlob`s: each per-holder encrypted deposit blob,
/// held until that holder's pickup is confirmed (relay-observed or heartbeat-attested), then
/// discarded by `ShareService`. Structurally identical to `LocalShareMetadataRepository`.
final class LocalRetainedDepositRepository: RetainedDepositRepository {

    private let fileURL: URL
    private var cache: [RetainedDepositBlob]?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("retained_deposits.json")
    }

    func getAll() throws -> [RetainedDepositBlob] {
        if let cached = cache { return cached }
        let blobs = (try? load()) ?? []
        cache = blobs
        return blobs
    }

    func save(_ blob: RetainedDepositBlob) throws {
        var all = (try? getAll()) ?? []
        all.removeAll { $0.id == blob.id }
        all.append(blob)
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

    private struct RetainedDepositBlobJSON: Codable {
        let id: String
        let secretId: String
        let contactId: String
        let label: String
        let secretCreatedAt: String
        let ciphertext: String
        let k: Int
        let n: Int
        let mimeType: String
    }

    private func load() throws -> [RetainedDepositBlob] {
        let data = try Data(contentsOf: fileURL)
        let items = try JSONDecoder().decode([RetainedDepositBlobJSON].self, from: data)
        return items.compactMap { json in
            guard let id = UUID(uuidString: json.id),
                  let secretId = UUID(uuidString: json.secretId),
                  let contactId = UUID(uuidString: json.contactId),
                  let secretCreatedAt = Self.isoFormatter.date(from: json.secretCreatedAt),
                  let ciphertext = Data(base64Encoded: json.ciphertext) else { return nil }
            return RetainedDepositBlob(id: id, secretId: secretId, contactId: contactId, label: json.label, secretCreatedAt: secretCreatedAt, ciphertext: ciphertext, k: json.k, n: json.n, mimeType: MimeType(json.mimeType))
        }
    }

    private func persist(_ blobs: [RetainedDepositBlob]) throws {
        let items = blobs.map { b in
            RetainedDepositBlobJSON(
                id: b.id.uuidString, secretId: b.secretId.uuidString, contactId: b.contactId.uuidString,
                label: b.label, secretCreatedAt: Self.isoFormatter.string(from: b.secretCreatedAt),
                ciphertext: b.ciphertext.base64EncodedString(), k: b.k, n: b.n, mimeType: b.mimeType.value
            )
        }
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
    }

    private static let isoFormatter = ISO8601DateFormatter()
}

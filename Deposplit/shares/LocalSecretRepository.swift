import hexagon
import Foundation

final class LocalSecretRepository: SecretRepository {

    private let fileURL: URL
    private var cache: [Secret]?

    init() {
        fileURL = AppFiles.url("secrets.json")
    }

    func getAll() throws -> [Secret] {
        if let cached = cache { return cached }
        let secrets = (try? load()) ?? []
        cache = secrets
        return secrets
    }

    func save(_ secret: Secret) throws {
        var all = (try? getAll()) ?? []
        all.removeAll { $0.id == secret.id }
        all.append(secret)
        cache = all
        try persist(all)
    }

    func delete(secretId: UUID) throws {
        var all = (try? getAll()) ?? []
        all.removeAll { $0.id == secretId }
        cache = all
        try persist(all)
    }

    // MARK: - Persistence

    private struct SecretJSON: Codable {
        let id: String
        let label: String
        let k: Int
        let n: Int
        let mimeType: String
        let secretCreatedAt: String
        let state: String
    }

    private func load() throws -> [Secret] {
        let data = try Data(contentsOf: fileURL)
        let items = try JSONDecoder().decode([SecretJSON].self, from: data)
        return items.compactMap { json in
            guard let id = UUID(uuidString: json.id),
                  let secretCreatedAt = _secretISO8601.date(from: json.secretCreatedAt),
                  let state = SecretState(rawValue: json.state) else { return nil }
            return Secret(id: id, label: json.label, mimeType: MimeType(json.mimeType), k: json.k, n: json.n, secretCreatedAt: secretCreatedAt, state: state)
        }
    }

    private func persist(_ secrets: [Secret]) throws {
        let items = secrets.map { s in
            SecretJSON(
                id: s.id.uuidString,
                label: s.label,
                k: s.k,
                n: s.n,
                mimeType: s.mimeType.value,
                secretCreatedAt: _secretISO8601.string(from: s.secretCreatedAt),
                state: s.state.rawValue
            )
        }
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
    }
}

private let _secretISO8601 = ISO8601DateFormatter()

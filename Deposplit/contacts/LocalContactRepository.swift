import Foundation

final class LocalContactRepository: ContactRepository {

    private let fileURL: URL
    private var cache: [Contact]?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("contacts.json")
    }

    func getAll() -> [Contact] {
        if let cached = cache { return cached }
        let contacts = (try? load()) ?? []
        cache = contacts
        return contacts
    }

    func getByEdKey(_ edPublicKey: Data) -> Contact? {
        getAll().first { $0.edPublicKey == edPublicKey }
    }

    func save(_ contact: Contact) {
        var all = getAll()
        all.removeAll { $0.id == contact.id }
        all.append(contact)
        cache = all
        try? persist(all)
    }

    func delete(contactId: UUID) {
        var all = getAll()
        all.removeAll { $0.id == contactId }
        cache = all
        try? persist(all)
    }

    // MARK: - Persistence

    private struct ContactJSON: Codable {
        let id: String
        let pseudonym: String
        let edPublicKey: String
        let xPublicKey: String
        let verificationLevel: VerificationLevel
        let verifiedAt: String?
        let addedAt: String
    }

    private func load() throws -> [Contact] {
        let data = try Data(contentsOf: fileURL)
        let items = try JSONDecoder().decode([ContactJSON].self, from: data)
        return items.compactMap { json in
            guard let id = UUID(uuidString: json.id),
                  let ed = Data(base64URLEncoded: json.edPublicKey),
                  let x = Data(base64URLEncoded: json.xPublicKey),
                  let addedAt = json.addedAt.parseISO8601() else { return nil }
            return Contact(
                id: id,
                pseudonym: json.pseudonym,
                edPublicKey: ed,
                xPublicKey: x,
                verificationLevel: json.verificationLevel,
                verifiedAt: json.verifiedAt?.parseISO8601(),
                addedAt: addedAt
            )
        }
    }

    private func persist(_ contacts: [Contact]) throws {
        let items = contacts.map { c in
            ContactJSON(
                id: c.id.uuidString,
                pseudonym: c.pseudonym,
                edPublicKey: c.edPublicKey.base64URLEncoded,
                xPublicKey: c.xPublicKey.base64URLEncoded,
                verificationLevel: c.verificationLevel,
                verifiedAt: c.verifiedAt.map { _localISO8601.string(from: $0) },
                addedAt: _localISO8601.string(from: c.addedAt)
            )
        }
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
    }
}

private let _localISO8601 = ISO8601DateFormatter()

private extension String {
    func parseISO8601() -> Date? { _localISO8601.date(from: self) }
}

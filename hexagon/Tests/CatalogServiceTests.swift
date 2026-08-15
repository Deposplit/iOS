import Testing
@testable import hexagon
import Foundation

private final class InMemoryContactRepositoryForCatalogTest: ContactRepository {
    private(set) var contacts: [Contact] = []
    func getAll() -> [Contact] { contacts }
    func getByEdKey(_ edPublicKey: Data) -> Contact? { contacts.first { $0.edPublicKey == edPublicKey } }
    func getById(_ id: UUID) -> Contact? { contacts.first { $0.id == id } }
    func save(_ contact: Contact) {
        contacts.removeAll { $0.id == contact.id }
        contacts.append(contact)
    }
    func delete(contactId: UUID) { contacts.removeAll { $0.id == contactId } }
}

private final class InMemorySecretRepositoryForCatalogTest: SecretRepository {
    private(set) var secrets: [Secret] = []
    func getAll() throws -> [Secret] { secrets }
    func save(_ secret: Secret) throws {
        secrets.removeAll { $0.id == secret.id }
        secrets.append(secret)
    }
    func delete(secretId: UUID) throws { secrets.removeAll { $0.id == secretId } }
}

private final class InMemoryShareMetadataRepositoryForCatalogTest: ShareMetadataRepository {
    private(set) var metas: [ShareMetadata] = []
    func getAll() throws -> [ShareMetadata] { metas }
    func save(_ share: ShareMetadata) throws {
        metas.removeAll { $0.id == share.id }
        metas.append(share)
    }
    func delete(shareId: UUID) throws { metas.removeAll { $0.id == shareId } }
}

private func makeContact(_ name: String) -> Contact {
    Contact(
        id: UUID(), pseudonym: name,
        edPublicKey: Data(repeating: 0x01, count: 32), xPublicKey: Data(repeating: 0x02, count: 32),
        verificationLevel: .veryHigh, verifiedAt: Date(), addedAt: Date()
    )
}

@Test func exportThenImportRoundTripsContactsSecretsAndShareMetadata() throws {
    let contactRepo = InMemoryContactRepositoryForCatalogTest()
    let secretRepo = InMemorySecretRepositoryForCatalogTest()
    let metaRepo = InMemoryShareMetadataRepositoryForCatalogTest()
    let exporter = CatalogService(contactRepository: contactRepo, secretRepository: secretRepo, shareMetadataRepository: metaRepo)

    let contact = makeContact("alice")
    contactRepo.save(contact)
    let secret = Secret(id: UUID(), label: "test", k: 2, n: 3, secretCreatedAt: Date(), state: .active)
    try secretRepo.save(secret)
    let meta = ShareMetadata(id: UUID(), secretId: secret.id, contactId: contact.id)
    try metaRepo.save(meta)

    let data = try exporter.exportCatalog()

    // Import into a fresh, empty set of repositories.
    let freshContactRepo = InMemoryContactRepositoryForCatalogTest()
    let freshSecretRepo = InMemorySecretRepositoryForCatalogTest()
    let freshMetaRepo = InMemoryShareMetadataRepositoryForCatalogTest()
    let importer = CatalogService(contactRepository: freshContactRepo, secretRepository: freshSecretRepo, shareMetadataRepository: freshMetaRepo)

    let added = try importer.importCatalog(data)

    #expect(added == 1)
    #expect(freshContactRepo.getAll().map(\.id) == [contact.id])
    #expect(try freshSecretRepo.getAll().map(\.id) == [secret.id])
    #expect(try freshMetaRepo.getAll().map(\.id) == [meta.id])
}

@Test func importDoesNotOverwriteAnExistingLocalContact() throws {
    let contactRepo = InMemoryContactRepositoryForCatalogTest()
    let secretRepo = InMemorySecretRepositoryForCatalogTest()
    let metaRepo = InMemoryShareMetadataRepositoryForCatalogTest()
    let svc = CatalogService(contactRepository: contactRepo, secretRepository: secretRepo, shareMetadataRepository: metaRepo)

    let localContact = makeContact("locally-edited-name")
    contactRepo.save(localContact)
    let staleImportedVersion = Contact(
        id: localContact.id, pseudonym: "stale-backup-name",
        edPublicKey: localContact.edPublicKey, xPublicKey: localContact.xPublicKey,
        verificationLevel: .veryLow, verifiedAt: nil, addedAt: localContact.addedAt
    )
    let catalog = Catalog(contacts: [staleImportedVersion], secrets: [], shareMetadata: [])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(catalog)

    let added = try svc.importCatalog(data)

    #expect(added == 0)
    #expect(contactRepo.getById(localContact.id)?.pseudonym == "locally-edited-name")
}

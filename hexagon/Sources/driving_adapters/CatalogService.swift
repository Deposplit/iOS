import Foundation

public final class CatalogService: CatalogManagement {
    private let contactRepository: any ContactRepository
    private let secretRepository: any SecretRepository
    private let shareMetadataRepository: any ShareMetadataRepository

    public init(
        contactRepository: any ContactRepository,
        secretRepository: any SecretRepository,
        shareMetadataRepository: any ShareMetadataRepository
    ) {
        self.contactRepository = contactRepository
        self.secretRepository = secretRepository
        self.shareMetadataRepository = shareMetadataRepository
    }

    public func exportCatalog() throws -> Data {
        let catalog = Catalog(
            contacts: contactRepository.getAll(),
            secrets: try secretRepository.getAll(),
            shareMetadata: try shareMetadataRepository.getAll()
        )
        return try CatalogCodec.encode(catalog)
    }

    public func importCatalog(_ data: Data) throws -> Int {
        let catalog = try CatalogCodec.decode(data)

        let existingContactIds = Set(contactRepository.getAll().map(\.id))
        var added = 0
        for contact in catalog.contacts where !existingContactIds.contains(contact.id) {
            contactRepository.save(contact)
            added += 1
        }

        let existingSecretIds = Set(((try? secretRepository.getAll()) ?? []).map(\.id))
        for secret in catalog.secrets where !existingSecretIds.contains(secret.id) {
            try? secretRepository.save(secret)
        }

        let existingMetaIds = Set(((try? shareMetadataRepository.getAll()) ?? []).map(\.id))
        for meta in catalog.shareMetadata where !existingMetaIds.contains(meta.id) {
            try? shareMetadataRepository.save(meta)
        }

        return added
    }
}

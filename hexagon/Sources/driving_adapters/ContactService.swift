import Foundation

public enum ContactError: Error, LocalizedError {
    case blankPseudonym
    case invalidKeySize
    public var errorDescription: String? {
        switch self {
        case .blankPseudonym: "Name must not be blank."
        case .invalidKeySize: "Invalid key size — expected 32 bytes."
        }
    }
}

public final class ContactService: ContactManagement {
    private let contactRepository: any ContactRepository

    public init(contactRepository: any ContactRepository) {
        self.contactRepository = contactRepository
    }

    public func listContacts() throws -> [Contact] {
        contactRepository.getAll()
    }

    public func addManually(pseudonym: String, edPublicKey: Data, xPublicKey: Data) throws {
        let name = pseudonym.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ContactError.blankPseudonym }
        guard edPublicKey.count == 32 else { throw ContactError.invalidKeySize }
        guard xPublicKey.count == 32 else { throw ContactError.invalidKeySize }
        let now = Date()
        contactRepository.save(Contact(
            id: UUID(),
            pseudonym: name,
            edPublicKey: edPublicKey,
            xPublicKey: xPublicKey,
            verificationLevel: .unverified,
            verifiedAt: nil,
            addedAt: now
        ))
    }

    public func addFromQr(pseudonym: String, edPublicKey: Data, xPublicKey: Data) throws {
        let name = pseudonym.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ContactError.blankPseudonym }
        guard edPublicKey.count == 32 else { throw ContactError.invalidKeySize }
        guard xPublicKey.count == 32 else { throw ContactError.invalidKeySize }
        let now = Date()
        contactRepository.save(Contact(
            id: UUID(),
            pseudonym: name,
            edPublicKey: edPublicKey,
            xPublicKey: xPublicKey,
            verificationLevel: .verified,
            verifiedAt: now,
            addedAt: now
        ))
    }

    public func deleteContact(contactId: UUID) throws {
        contactRepository.delete(contactId: contactId)
    }
}

import Foundation

public enum ContactError: Error, LocalizedError {
    case blankPseudonym
    case invalidKeySize
    case veryHighRequiresInPersonScan
    case contactNotFound
    case levelRequiredOnKeyChange
    public var errorDescription: String? {
        switch self {
        case .blankPseudonym: "Name must not be blank."
        case .invalidKeySize: "Invalid key size — expected 32 bytes."
        case .veryHighRequiresInPersonScan: "Very High verification requires an in-person QR scan."
        case .contactNotFound: "Contact not found."
        case .levelRequiredOnKeyChange: "A verification level must be chosen fresh whenever a contact's keys change."
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

    public func addManually(pseudonym: String, edPublicKey: Data, xPublicKey: Data, verificationLevel: VerificationLevel, relayBaseUrl: String?) throws {
        let name = pseudonym.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ContactError.blankPseudonym }
        guard edPublicKey.count == 32 else { throw ContactError.invalidKeySize }
        guard xPublicKey.count == 32 else { throw ContactError.invalidKeySize }
        // Physical co-presence can't be asserted by typing a key in by hand — that's what the
        // in-person QR scan flow is for. See CLAUDE.md item 6.
        guard verificationLevel != .veryHigh else { throw ContactError.veryHighRequiresInPersonScan }
        let now = Date()
        contactRepository.save(Contact(
            id: UUID(),
            pseudonym: name,
            edPublicKey: edPublicKey,
            xPublicKey: xPublicKey,
            verificationLevel: verificationLevel,
            verifiedAt: now,
            addedAt: now,
            relayBaseUrl: relayBaseUrl
        ))
    }

    public func addFromQr(pseudonym: String, edPublicKey: Data, xPublicKey: Data, verificationLevel: VerificationLevel, relayBaseUrl: String?) throws {
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
            verificationLevel: verificationLevel,
            verifiedAt: now,
            addedAt: now,
            relayBaseUrl: relayBaseUrl
        ))
    }

    public func updateContact(contactId: UUID, edPublicKey: Data?, xPublicKey: Data?, verificationLevel: VerificationLevel?) throws {
        guard let existing = contactRepository.getById(contactId) else { throw ContactError.contactNotFound }
        let changingKeys = edPublicKey != nil || xPublicKey != nil
        if changingKeys && verificationLevel == nil { throw ContactError.levelRequiredOnKeyChange }
        if let ed = edPublicKey { guard ed.count == 32 else { throw ContactError.invalidKeySize } }
        if let x = xPublicKey { guard x.count == 32 else { throw ContactError.invalidKeySize } }
        contactRepository.save(Contact(
            id: existing.id,
            pseudonym: existing.pseudonym,
            edPublicKey: edPublicKey ?? existing.edPublicKey,
            xPublicKey: xPublicKey ?? existing.xPublicKey,
            verificationLevel: verificationLevel ?? existing.verificationLevel,
            verifiedAt: verificationLevel != nil ? Date() : existing.verifiedAt,
            addedAt: existing.addedAt,
            relayBaseUrl: existing.relayBaseUrl
        ))
    }

    public func deleteContact(contactId: UUID) throws {
        contactRepository.delete(contactId: contactId)
    }
}

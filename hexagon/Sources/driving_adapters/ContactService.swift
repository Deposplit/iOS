import Foundation

public enum ContactError: Error, LocalizedError {
    case blankPseudonym
    case invalidKeySize
    case veryHighRequiresInPersonScan
    case contactNotFound
    case levelRequiredOnKeyChange
    case premiumRequired
    public var errorDescription: String? {
        switch self {
        case .blankPseudonym: "Name must not be blank."
        case .invalidKeySize: "Invalid key size — expected 32 bytes."
        case .veryHighRequiresInPersonScan: "Very High verification requires an in-person QR scan."
        case .contactNotFound: "Contact not found."
        case .levelRequiredOnKeyChange: "A verification level must be chosen fresh whenever a contact's keys change."
        case .premiumRequired: "This requires the Deposplit Premium unlock."
        }
    }
}

public final class ContactService: ContactManagement {
    private let contactRepository: any ContactRepository
    private let purchases: any PurchaseRepository

    public init(contactRepository: any ContactRepository, purchases: any PurchaseRepository) {
        self.contactRepository = contactRepository
        self.purchases = purchases
    }

    public func listContacts() throws -> [Contact] {
        contactRepository.getAll()
    }

    public func addManually(pseudonym: String, verifyKey: Data, encKey: Data, verificationLevel: VerificationLevel, relayBaseUrl: String?, nickname: String?) throws {
        let name = pseudonym.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ContactError.blankPseudonym }
        // Manual entry has no wire-carried suite info — only one suite exists to assume.
        let cipherSuite = CipherSuite.current
        guard verifyKey.count == cipherSuite.verifyKeyLength else { throw ContactError.invalidKeySize }
        guard encKey.count == cipherSuite.encKeyLength else { throw ContactError.invalidKeySize }
        // Physical co-presence can't be asserted by typing a key in by hand — that's what the
        // in-person QR scan flow is for.
        guard verificationLevel != .veryHigh else { throw ContactError.veryHighRequiresInPersonScan }
        // Typing a relay by hand is the paid half of BYOR. Reading one out of a scanned QR code is
        // not, and `addFromQr` below is deliberately left open: that URL is the contact stating
        // where their own mailbox is, and refusing it would mean a free device simply cannot share
        // with anyone who self-hosts.
        if relayBaseUrl != nil, !purchases.isPremium() { throw ContactError.premiumRequired }
        let now = Date()
        contactRepository.save(Contact(
            id: UUID(),
            pseudonym: name,
            verifyKey: verifyKey,
            encKey: encKey,
            verificationLevel: verificationLevel,
            verifiedAt: now,
            addedAt: now,
            relayBaseUrl: relayBaseUrl,
            cipherSuite: cipherSuite,
            nickname: Self.normalizeNickname(nickname)
        ))
    }

    public func addFromQr(pseudonym: String, verifyKey: Data, encKey: Data, cipherSuite: CipherSuite, verificationLevel: VerificationLevel, relayBaseUrl: String?, nickname: String?) throws {
        let name = pseudonym.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ContactError.blankPseudonym }
        guard verifyKey.count == cipherSuite.verifyKeyLength else { throw ContactError.invalidKeySize }
        guard encKey.count == cipherSuite.encKeyLength else { throw ContactError.invalidKeySize }
        let now = Date()
        contactRepository.save(Contact(
            id: UUID(),
            pseudonym: name,
            verifyKey: verifyKey,
            encKey: encKey,
            verificationLevel: verificationLevel,
            verifiedAt: now,
            addedAt: now,
            relayBaseUrl: relayBaseUrl,
            cipherSuite: cipherSuite,
            nickname: Self.normalizeNickname(nickname)
        ))
    }

    public func updateContact(contactId: UUID, verifyKey: Data?, encKey: Data?, newCipherSuite: CipherSuite?, verificationLevel: VerificationLevel?) throws {
        guard let existing = contactRepository.getById(contactId) else { throw ContactError.contactNotFound }
        // A cipher-suite-only change (no key-value change) forces the same fresh-level
        // rule as a key change: an algorithm change is still continuity of key control, not a
        // personhood assurance.
        let changingIdentity = verifyKey != nil || encKey != nil || newCipherSuite != nil
        if changingIdentity && verificationLevel == nil { throw ContactError.levelRequiredOnKeyChange }
        let resolvedSuite = newCipherSuite ?? existing.cipherSuite
        if let ed = verifyKey { guard ed.count == resolvedSuite.verifyKeyLength else { throw ContactError.invalidKeySize } }
        if let x = encKey { guard x.count == resolvedSuite.encKeyLength else { throw ContactError.invalidKeySize } }
        contactRepository.save(Contact(
            id: existing.id,
            pseudonym: existing.pseudonym,
            verifyKey: verifyKey ?? existing.verifyKey,
            encKey: encKey ?? existing.encKey,
            verificationLevel: verificationLevel ?? existing.verificationLevel,
            verifiedAt: verificationLevel != nil ? Date() : existing.verifiedAt,
            addedAt: existing.addedAt,
            relayBaseUrl: existing.relayBaseUrl,
            revokedVerifyKeys: existing.revokedVerifyKeys,
            keyChangedAt: changingIdentity ? Date() : existing.keyChangedAt,
            heartbeatOptedOutAt: existing.heartbeatOptedOutAt,
            lastHeartbeatSentAt: existing.lastHeartbeatSentAt,
            heartbeatEmissionOptedOut: existing.heartbeatEmissionOptedOut,
            cipherSuite: resolvedSuite,
            nickname: existing.nickname
        ))
    }

    /// Deliberately separate from `updateContact`: never touches keys, cipherSuite,
    /// verificationLevel, verifiedAt, or keyChangedAt. Pass nil to clear an existing nickname.
    public func renameContact(contactId: UUID, nickname: String?) throws {
        guard let existing = contactRepository.getById(contactId) else { throw ContactError.contactNotFound }
        contactRepository.save(Contact(
            id: existing.id,
            pseudonym: existing.pseudonym,
            verifyKey: existing.verifyKey,
            encKey: existing.encKey,
            verificationLevel: existing.verificationLevel,
            verifiedAt: existing.verifiedAt,
            addedAt: existing.addedAt,
            relayBaseUrl: existing.relayBaseUrl,
            revokedVerifyKeys: existing.revokedVerifyKeys,
            keyChangedAt: existing.keyChangedAt,
            heartbeatOptedOutAt: existing.heartbeatOptedOutAt,
            lastHeartbeatSentAt: existing.lastHeartbeatSentAt,
            heartbeatEmissionOptedOut: existing.heartbeatEmissionOptedOut,
            cipherSuite: existing.cipherSuite,
            nickname: Self.normalizeNickname(nickname)
        ))
    }

    public func deleteContact(contactId: UUID) throws {
        contactRepository.delete(contactId: contactId)
    }

    public func markKeyCompromised(contactId: UUID, verifyKey: Data?) throws {
        guard let existing = contactRepository.getById(contactId) else { throw ContactError.contactNotFound }
        let flagged = verifyKey ?? existing.verifyKey
        guard !existing.revokedVerifyKeys.contains(flagged) else { return }
        contactRepository.save(Contact(
            id: existing.id,
            pseudonym: existing.pseudonym,
            verifyKey: existing.verifyKey,
            encKey: existing.encKey,
            verificationLevel: existing.verificationLevel,
            verifiedAt: existing.verifiedAt,
            addedAt: existing.addedAt,
            relayBaseUrl: existing.relayBaseUrl,
            revokedVerifyKeys: existing.revokedVerifyKeys + [flagged],
            keyChangedAt: existing.keyChangedAt,
            heartbeatOptedOutAt: existing.heartbeatOptedOutAt,
            lastHeartbeatSentAt: existing.lastHeartbeatSentAt,
            heartbeatEmissionOptedOut: existing.heartbeatEmissionOptedOut,
            cipherSuite: existing.cipherSuite,
            nickname: existing.nickname
        ))
    }

    // Trim, then collapse blank to nil. Lives here (not the UI layer) so every
    // caller — UI, tests, a future relink flow — gets consistent normalization for free.
    private static func normalizeNickname(_ nickname: String?) -> String? {
        guard let trimmed = nickname?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

import Foundation

public enum ShareServiceError: Error, LocalizedError {
    case contactNotFound
    public var errorDescription: String? {
        switch self {
        case .contactNotFound: "Contact not found — cannot decrypt share."
        }
    }
}

public final class ShareService: ShareManagement {
    private let relay: any ShareRelay
    private let encryption: any ShareEncryption
    private let shareRepository: any ShareRepository
    private let shareMetadataRepository: any ShareMetadataRepository
    private let contactRepository: any ContactRepository

    public init(
        relay: any ShareRelay,
        encryption: any ShareEncryption,
        shareRepository: any ShareRepository,
        shareMetadataRepository: any ShareMetadataRepository,
        contactRepository: any ContactRepository
    ) {
        self.relay = relay
        self.encryption = encryption
        self.shareRepository = shareRepository
        self.shareMetadataRepository = shareMetadataRepository
        self.contactRepository = contactRepository
    }

    public func deposit(secret: Data, label: String, contacts: [Contact], threshold: Int) async throws {
        let shares = try split(secret: Array(secret), shares: contacts.count, threshold: threshold)
        let secretId = UUID()
        for (contact, share) in zip(contacts, shares) {
            let ciphertext = try encryption.encrypt(Data(share), recipientXPublicKey: contact.xPublicKey)
            let metadata = try await relay.depositShare(
                secretId: secretId,
                label: label,
                recipientKey: contact.edPublicKey,
                ciphertext: ciphertext
            )
            try? shareMetadataRepository.save(metadata)
        }
    }

    public func listDistributed() throws -> [ShareMetadata] {
        try shareMetadataRepository.getAll()
    }

    public func syncDistributed() async throws {
        let shares = try await relay.listShares(role: .sender, counterpartyKey: nil)
        for share in shares {
            try? shareMetadataRepository.save(share)
        }
    }

    public func listSentRequests() async throws -> [ShareRequest] {
        try await relay.listShareRequests(role: .sender, state: nil)
    }

    public func requestAll(secretId: UUID) async throws {
        let distributed = try await relay.listShares(role: .sender, counterpartyKey: nil)
        let forSecret = distributed.filter { $0.secretId == secretId }
        let existing = try await relay.listShareRequests(role: .sender, state: nil)
        for share in forSecret {
            let hasActive = existing.contains {
                $0.share.id == share.id &&
                $0.requestType == .retrieve &&
                ($0.state == .pending || $0.state == .approved)
            }
            if !hasActive {
                _ = try? await relay.openShareRequest(shareId: share.id, type: .retrieve)
            }
        }
    }

    public func openRequest(shareId: UUID, type: ShareRequestType) async throws -> ShareRequest {
        try await relay.openShareRequest(shareId: shareId, type: type)
    }

    public func reconstruct(secretId: UUID) async throws -> Data {
        let approved = try await relay.listShareRequests(role: .sender, state: .approved)
        let retrieves = approved.filter {
            $0.share.secretId == secretId && $0.requestType == .retrieve && $0.ciphertext != nil
        }
        let decryptedShares: [[UInt8]] = try retrieves.map { req in
            let ct = req.ciphertext!
            guard let contact = contactRepository.getByEdKey(req.share.recipientKey) else {
                throw ShareServiceError.contactNotFound
            }
            let plaintext = try encryption.decrypt(ct, recipientXPublicKey: contact.xPublicKey)
            return Array(plaintext)
        }
        let secretBytes = try combine(shares: decryptedShares)
        for req in retrieves {
            try? await relay.deleteShare(shareId: req.share.id)
            try? shareMetadataRepository.delete(shareId: req.share.id)
        }
        return Data(secretBytes)
    }

    public func syncInbox() async throws {
        let inbox = try await relay.listShares(role: .recipient, counterpartyKey: nil)
        for meta in inbox {
            if shareRepository.getCiphertext(shareId: meta.id) == nil {
                if let ct = try? await relay.pickUpShare(shareId: meta.id) {
                    shareRepository.save(HeldShare(
                        id: meta.id,
                        secretId: meta.secretId,
                        label: meta.label,
                        senderKey: meta.senderKey,
                        createdAt: meta.createdAt,
                        pickedUpAt: Date(),
                        ciphertext: ct
                    ))
                }
            }
        }
    }

    public func listHeld() throws -> [HeldShare] {
        shareRepository.getAll()
    }

    public func listPendingRequests() async throws -> [ShareRequest] {
        try await relay.listShareRequests(role: .recipient, state: .pending)
    }

    public func respond(requestId: UUID, approved: Bool) async throws {
        let request = try await relay.getShareRequest(requestId: requestId)
        let ciphertext: Data? = if approved && request.requestType == .retrieve {
            shareRepository.getCiphertext(shareId: request.share.id)
        } else {
            nil
        }
        _ = try await relay.respondToShareRequest(requestId: requestId, approved: approved, ciphertext: ciphertext)
        if approved && request.requestType == .delete {
            shareRepository.delete(shareId: request.share.id)
        }
    }

    public func deleteHeldShare(shareId: UUID) async throws {
        shareRepository.delete(shareId: shareId)
    }

    public func deleteAllHeldFromSender(senderKey: Data) async throws {
        for share in shareRepository.getAll() where share.senderKey == senderKey {
            shareRepository.delete(shareId: share.id)
        }
    }
}

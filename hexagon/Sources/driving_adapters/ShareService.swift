import Foundation

public enum ShareServiceError: Error, LocalizedError {
    case contactNotFound
    case shareNotFound
    case missingShareId
    case notEnoughApprovedShares(Int)
    public var errorDescription: String? {
        switch self {
        case .contactNotFound: "Contact not found — cannot decrypt share."
        case .shareNotFound: "No local share record found."
        case .missingShareId: "Retrieve request has no associated share ID."
        case .notEnoughApprovedShares(let count): "Need at least 2 approved shares (have \(count))."
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

    // MARK: - Sender flows

    public func deposit(secret: Data, label: String, contacts: [Contact], threshold: Int) async throws {
        let shares = try split(secret: Array(secret), shares: contacts.count, threshold: threshold)
        let secretId = UUID()
        let createdAt = Date()
        for (contact, share) in zip(contacts, shares) {
            let ciphertext = try encryption.encrypt(Data(share), recipientXPublicKey: contact.xPublicKey)
            let req = try await relay.openShareRequest(
                secretId: secretId,
                recipientKey: contact.edPublicKey,
                label: label,
                secretCreatedAt: createdAt,
                requestType: .pickUp,
                shareId: nil,
                ciphertext: ciphertext
            )
            try? shareMetadataRepository.save(ShareMetadata(id: req.id, secretId: secretId, label: label, recipientKey: contact.edPublicKey, secretCreatedAt: createdAt))
        }
    }

    public func listDistributed() throws -> [ShareMetadata] {
        try shareMetadataRepository.getAll()
    }

    public func syncDistributed() async throws {
        let reqs = try await relay.listShareRequests(role: .sender, requestType: .pickUp, state: nil)
        for req in reqs {
            try? shareMetadataRepository.save(ShareMetadata(id: req.id, secretId: req.secretId, label: req.label, recipientKey: req.recipientKey, secretCreatedAt: req.secretCreatedAt))
        }
    }

    public func listSentRequests() async throws -> [ShareRequest] {
        let all = try await relay.listShareRequests(role: .sender, requestType: nil, state: nil)
        return all.filter { $0.requestType != .pickUp }
    }

    public func requestAll(secretId: UUID) async throws {
        let deposited = (try? shareMetadataRepository.getAll()) ?? []
        let forSecret = deposited.filter { $0.secretId == secretId }
        let existing = try await relay.listShareRequests(role: .sender, requestType: .retrieve, state: nil)
        for meta in forSecret {
            let hasActive = existing.contains {
                $0.shareId == meta.id && ($0.state == .pending || $0.state == .approved)
            }
            if !hasActive {
                _ = try? await relay.openShareRequest(
                    secretId: meta.secretId,
                    recipientKey: meta.recipientKey,
                    label: meta.label,
                    secretCreatedAt: meta.secretCreatedAt,
                    requestType: .retrieve,
                    shareId: meta.id,
                    ciphertext: nil
                )
            }
        }
    }

    public func openRequest(shareId: UUID, type: ShareRequestType) async throws -> ShareRequest {
        let all = (try? shareMetadataRepository.getAll()) ?? []
        guard let meta = all.first(where: { $0.id == shareId }) else {
            throw ShareServiceError.shareNotFound
        }
        return try await relay.openShareRequest(
            secretId: meta.secretId,
            recipientKey: meta.recipientKey,
            label: meta.label,
            secretCreatedAt: meta.secretCreatedAt,
            requestType: type,
            shareId: shareId,
            ciphertext: nil
        )
    }

    public func reconstruct(secretId: UUID) async throws -> Data {
        let all = try await relay.listShareRequests(role: .sender, requestType: .retrieve, state: nil)
        let approved = all.filter { $0.secretId == secretId && $0.state == .approved && $0.ciphertext != nil }
        guard approved.count >= 2 else {
            throw ShareServiceError.notEnoughApprovedShares(approved.count)
        }
        let decryptedShares: [[UInt8]] = try approved.map { req in
            let ct = req.ciphertext!
            guard let contact = contactRepository.getByEdKey(req.recipientKey) else {
                throw ShareServiceError.contactNotFound
            }
            let plaintext = try encryption.decrypt(ct, recipientXPublicKey: contact.xPublicKey)
            return Array(plaintext)
        }
        let secretBytes = try combine(shares: decryptedShares)
        for req in approved {
            if let pickUpId = req.shareId {
                try? await relay.deleteShareRequest(requestId: pickUpId)
                try? shareMetadataRepository.delete(shareId: pickUpId)
            }
        }
        return Data(secretBytes)
    }

    // MARK: - Recipient flows

    public func syncInbox() async throws {
        let pending = try await relay.listShareRequests(role: .recipient, requestType: .pickUp, state: .pending)
        for req in pending {
            if shareRepository.getCiphertext(shareId: req.id) == nil {
                if let responded = try? await relay.respondToShareRequest(requestId: req.id, approved: true, ciphertext: nil),
                   let ct = responded.ciphertext {
                    shareRepository.save(HeldShare(
                        id: req.id,
                        secretId: req.secretId,
                        label: req.label,
                        senderKey: req.senderKey,
                        createdAt: req.secretCreatedAt,
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
        let all = try await relay.listShareRequests(role: .recipient, requestType: nil, state: .pending)
        return all.filter { $0.requestType != .pickUp }
    }

    public func respond(requestId: UUID, approved: Bool) async throws {
        let request = try await relay.getShareRequest(requestId: requestId)
        let ciphertext: Data?
        if approved && request.requestType == .retrieve {
            guard let pickUpId = request.shareId else {
                throw ShareServiceError.missingShareId
            }
            ciphertext = shareRepository.getCiphertext(shareId: pickUpId)
        } else {
            ciphertext = nil
        }
        _ = try await relay.respondToShareRequest(requestId: requestId, approved: approved, ciphertext: ciphertext)
        if approved && request.requestType == .delete {
            if let pickUpId = request.shareId {
                shareRepository.delete(shareId: pickUpId)
            }
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

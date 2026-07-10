import Foundation

public enum ShareServiceError: Error, LocalizedError {
    case contactNotFound
    case shareNotFound
    case missingShareId
    case notEnoughApprovedShares(Int)
    case signatureVerificationFailed(String)
    case shareRequestNotFoundOnAnyRelay(UUID)
    public var errorDescription: String? {
        switch self {
        case .contactNotFound: "Contact not found — cannot decrypt share."
        case .shareNotFound: "No local share record found."
        case .missingShareId: "Retrieve request has no associated share ID."
        case .notEnoughApprovedShares(let count): "Need at least 2 approved shares (have \(count))."
        case .signatureVerificationFailed(let detail): "Signature verification failed: \(detail)"
        case .shareRequestNotFoundOnAnyRelay(let id): "Share request \(id) not found on any known relay."
        }
    }
}

public final class ShareService: ShareManagement {
    private let relayResolver: any ShareRelayResolver
    private let encryption: any ShareEncryption
    private let shareRepository: any ShareRepository
    private let shareMetadataRepository: any ShareMetadataRepository
    private let contactRepository: any ContactRepository
    private let identity: any Identity

    public init(
        relayResolver: any ShareRelayResolver,
        encryption: any ShareEncryption,
        shareRepository: any ShareRepository,
        shareMetadataRepository: any ShareMetadataRepository,
        contactRepository: any ContactRepository,
        identity: any Identity
    ) {
        self.relayResolver = relayResolver
        self.encryption = encryption
        self.shareRepository = shareRepository
        self.shareMetadataRepository = shareMetadataRepository
        self.contactRepository = contactRepository
        self.identity = identity
    }

    // MARK: - Relay resolution

    /// Every distinct relay referenced across the contact list, plus the default — used by
    /// fan-out methods (syncInbox, listPendingRequests, syncDistributed, listSentRequests) since
    /// a device has no other way to know in advance which relay a given contact's pending item
    /// lives on. Deduped by URL, not per-contact; each relay call is independently soft-failed so
    /// one unreachable BYOR relay doesn't blank out results from the default relay or others.
    private func allRelays() -> [any ShareRelay] {
        var urls = Set(contactRepository.getAll().map { $0.relayBaseUrl })
        urls.insert(nil)
        return urls.map { relayResolver.resolve($0) }
    }

    private func relay(for contact: Contact) -> any ShareRelay {
        relayResolver.resolve(contact.relayBaseUrl)
    }

    private func relay(forKey edPublicKey: Data) -> any ShareRelay {
        relayResolver.resolve(contactRepository.getByEdKey(edPublicKey)?.relayBaseUrl)
    }

    /// Finds a row by id across every known relay — the caller (UI) has no relay context for a
    /// bare requestId, only the fan-out list already used to discover it. Returns the relay it
    /// was found on too, so the caller can act on it through the *same* relay rather than
    /// re-resolving (which could point elsewhere if a contact's relayBaseUrl changed since the
    /// row was created).
    private func findShareRequest(_ requestId: UUID) async throws -> (relay: any ShareRelay, request: ShareRequest) {
        for relay in allRelays() {
            if let request = try? await relay.getShareRequest(requestId: requestId) {
                return (relay: relay, request: request)
            }
        }
        throw ShareServiceError.shareRequestNotFoundOnAnyRelay(requestId)
    }

    // MARK: - Signature helpers

    /// True only if `req`'s senderSignature verifies against a known contact's Ed25519 key.
    private func verifyOpen(_ req: ShareRequest) -> Bool {
        guard let contact = contactRepository.getByEdKey(req.senderKey) else { return false }
        let canon = PayloadCanonical.forOpen(
            secretId: req.secretId, requestType: req.requestType, recipientKey: req.recipientKey,
            label: req.label, secretCreatedAt: req.secretCreatedAt, shareId: req.shareId, ciphertext: req.ciphertext
        )
        return identity.verify(canon, signature: req.senderSignature, publicKey: contact.edPublicKey)
    }

    /// True only if `req`'s recipientSignature verifies against a known contact's Ed25519 key.
    /// Reconstructs the exact bytes the recipient signed: for a PickUp approval the recipient
    /// never supplies ciphertext (the relay returns Alice's), so that case signs over
    /// `ciphertext = nil` even though the row's own ciphertext field is populated for delivery.
    private func verifyRespond(_ req: ShareRequest) -> Bool {
        guard let sig = req.recipientSignature else { return false }
        guard let contact = contactRepository.getByEdKey(req.recipientKey) else { return false }
        let approved = req.state == .approved
        let signedCiphertext = (approved && req.requestType == .retrieve) ? req.ciphertext : nil
        let canon = PayloadCanonical.forRespond(requestId: req.id, approved: approved, ciphertext: signedCiphertext)
        return identity.verify(canon, signature: sig, publicKey: contact.edPublicKey)
    }

    // MARK: - Sender flows

    public func deposit(secret: Data, label: String, contacts: [Contact], threshold: Int) async throws {
        let shares = try split(secret: Array(secret), shares: contacts.count, threshold: threshold)
        let secretId = UUID()
        let createdAt = Date()
        for (contact, share) in zip(contacts, shares) {
            let ciphertext = try encryption.encrypt(Data(share), recipientXPublicKey: contact.xPublicKey)
            let canon = PayloadCanonical.forOpen(secretId: secretId, requestType: .pickUp, recipientKey: contact.edPublicKey, label: label, secretCreatedAt: createdAt, shareId: nil, ciphertext: ciphertext)
            let senderSignature = try identity.sign(canon)
            let req = try await relay(for: contact).openShareRequest(
                secretId: secretId,
                recipientKey: contact.edPublicKey,
                label: label,
                secretCreatedAt: createdAt,
                requestType: .pickUp,
                shareId: nil,
                ciphertext: ciphertext,
                senderSignature: senderSignature
            )
            try? shareMetadataRepository.save(ShareMetadata(id: req.id, secretId: secretId, label: label, recipientKey: contact.edPublicKey, secretCreatedAt: createdAt))
        }
    }

    public func listDistributed() throws -> [ShareMetadata] {
        try shareMetadataRepository.getAll()
    }

    public func syncDistributed() async throws {
        for relay in allRelays() {
            let reqs = (try? await relay.listShareRequests(role: .sender, requestType: .pickUp, state: nil)) ?? []
            for req in reqs {
                try? shareMetadataRepository.save(ShareMetadata(id: req.id, secretId: req.secretId, label: req.label, recipientKey: req.recipientKey, secretCreatedAt: req.secretCreatedAt))
            }
        }
    }

    public func listSentRequests() async throws -> [ShareRequest] {
        var all: [ShareRequest] = []
        for relay in allRelays() {
            all += (try? await relay.listShareRequests(role: .sender, requestType: nil, state: nil)) ?? []
        }
        return all.filter { $0.requestType != .pickUp }
    }

    public func requestAll(secretId: UUID) async throws {
        let deposited = (try? shareMetadataRepository.getAll()) ?? []
        let forSecret = deposited.filter { $0.secretId == secretId }
        var existing: [ShareRequest] = []
        for relay in allRelays() {
            existing += (try? await relay.listShareRequests(role: .sender, requestType: .retrieve, state: nil)) ?? []
        }
        for meta in forSecret {
            let hasActive = existing.contains {
                $0.shareId == meta.id && ($0.state == .pending || $0.state == .approved)
            }
            if !hasActive {
                let canon = PayloadCanonical.forOpen(secretId: meta.secretId, requestType: .retrieve, recipientKey: meta.recipientKey, label: meta.label, secretCreatedAt: meta.secretCreatedAt, shareId: meta.id, ciphertext: nil)
                if let senderSignature = try? identity.sign(canon) {
                    _ = try? await relay(forKey: meta.recipientKey).openShareRequest(
                        secretId: meta.secretId,
                        recipientKey: meta.recipientKey,
                        label: meta.label,
                        secretCreatedAt: meta.secretCreatedAt,
                        requestType: .retrieve,
                        shareId: meta.id,
                        ciphertext: nil,
                        senderSignature: senderSignature
                    )
                }
            }
        }
    }

    public func openRequest(shareId: UUID, type: ShareRequestType) async throws -> ShareRequest {
        let all = (try? shareMetadataRepository.getAll()) ?? []
        guard let meta = all.first(where: { $0.id == shareId }) else {
            throw ShareServiceError.shareNotFound
        }
        let canon = PayloadCanonical.forOpen(secretId: meta.secretId, requestType: type, recipientKey: meta.recipientKey, label: meta.label, secretCreatedAt: meta.secretCreatedAt, shareId: shareId, ciphertext: nil)
        let senderSignature = try identity.sign(canon)
        return try await relay(forKey: meta.recipientKey).openShareRequest(
            secretId: meta.secretId,
            recipientKey: meta.recipientKey,
            label: meta.label,
            secretCreatedAt: meta.secretCreatedAt,
            requestType: type,
            shareId: shareId,
            ciphertext: nil,
            senderSignature: senderSignature
        )
    }

    public func reconstruct(secretId: UUID) async throws -> Data {
        var allRequests: [(relay: any ShareRelay, request: ShareRequest)] = []
        for relay in allRelays() {
            let reqs = (try? await relay.listShareRequests(role: .sender, requestType: .retrieve, state: nil)) ?? []
            allRequests += reqs.map { (relay: relay, request: $0) }
        }
        // An unverified recipientSignature is treated as "not yet approved" rather than a hard
        // error — a forged approval simply doesn't count toward the threshold.
        let approved = allRequests.filter { pair in
            pair.request.secretId == secretId && pair.request.state == .approved && pair.request.ciphertext != nil && verifyRespond(pair.request)
        }
        guard approved.count >= 2 else {
            throw ShareServiceError.notEnoughApprovedShares(approved.count)
        }
        let decryptedShares: [[UInt8]] = try approved.map { pair in
            let ct = pair.request.ciphertext!
            guard let contact = contactRepository.getByEdKey(pair.request.recipientKey) else {
                throw ShareServiceError.contactNotFound
            }
            let plaintext = try encryption.decrypt(ct, recipientXPublicKey: contact.xPublicKey)
            return Array(plaintext)
        }
        let secretBytes = try combine(shares: decryptedShares)
        // Delete via the same relay each row was found on — the relay cascades to Retrieve/Delete rows.
        for pair in approved {
            if let pickUpId = pair.request.shareId {
                try? await pair.relay.deleteShareRequest(requestId: pickUpId)
                try? shareMetadataRepository.delete(shareId: pickUpId)
            }
        }
        return Data(secretBytes)
    }

    // MARK: - Recipient flows

    public func syncInbox() async throws {
        for relay in allRelays() {
            let pending = (try? await relay.listShareRequests(role: .recipient, requestType: .pickUp, state: .pending)) ?? []
            // Unknown sender or unverified senderSignature: skip silently, do not auto-approve.
            for req in pending where verifyOpen(req) {
                if shareRepository.getCiphertext(shareId: req.id) == nil {
                    let canon = PayloadCanonical.forRespond(requestId: req.id, approved: true, ciphertext: nil)
                    guard let recipientSignature = try? identity.sign(canon) else { continue }
                    if let responded = try? await relay.respondToShareRequest(requestId: req.id, approved: true, ciphertext: nil, recipientSignature: recipientSignature),
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
    }

    public func listHeld() throws -> [HeldShare] {
        shareRepository.getAll()
    }

    public func listPendingRequests() async throws -> [ShareRequest] {
        var all: [ShareRequest] = []
        for relay in allRelays() {
            all += (try? await relay.listShareRequests(role: .recipient, requestType: nil, state: .pending)) ?? []
        }
        // A forged delete/retrieve request has no AEAD backstop — must never reach the UI.
        return all.filter { $0.requestType != .pickUp && verifyOpen($0) }
    }

    public func respond(requestId: UUID, approved: Bool) async throws {
        let (relay, request) = try await findShareRequest(requestId)
        guard verifyOpen(request) else {
            throw ShareServiceError.signatureVerificationFailed("senderSignature does not verify for request \(requestId)")
        }
        let ciphertext: Data?
        if approved && request.requestType == .retrieve {
            guard let pickUpId = request.shareId else {
                throw ShareServiceError.missingShareId
            }
            ciphertext = shareRepository.getCiphertext(shareId: pickUpId)
        } else {
            ciphertext = nil
        }
        let canon = PayloadCanonical.forRespond(requestId: requestId, approved: approved, ciphertext: ciphertext)
        let recipientSignature = try identity.sign(canon)
        _ = try await relay.respondToShareRequest(requestId: requestId, approved: approved, ciphertext: ciphertext, recipientSignature: recipientSignature)
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

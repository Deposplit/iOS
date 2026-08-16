import Foundation

public enum ShareServiceError: Error, LocalizedError {
    case contactNotFound
    case shareNotFound
    case secretNotFound
    case notEnoughApprovedShares(have: Int, need: Int)
    case signatureVerificationFailed(String)
    case shareRequestNotFoundOnAnyRelay(UUID)
    public var errorDescription: String? {
        switch self {
        case .contactNotFound: "Contact not found — cannot decrypt share."
        case .shareNotFound: "No local share record found."
        case .secretNotFound: "No local record for this secret."
        case .notEnoughApprovedShares(let have, let need): "Need at least \(need) approved shares (have \(have))."
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
    private let secretRepository: any SecretRepository
    private let contactRepository: any ContactRepository
    private let identity: any Identity

    public init(
        relayResolver: any ShareRelayResolver,
        encryption: any ShareEncryption,
        shareRepository: any ShareRepository,
        shareMetadataRepository: any ShareMetadataRepository,
        secretRepository: any SecretRepository,
        contactRepository: any ContactRepository,
        identity: any Identity
    ) {
        self.relayResolver = relayResolver
        self.encryption = encryption
        self.shareRepository = shareRepository
        self.shareMetadataRepository = shareMetadataRepository
        self.secretRepository = secretRepository
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
            secretId: req.secretId, transactionType: req.transactionType, recipientKey: req.recipientKey,
            label: req.label, secretCreatedAt: req.secretCreatedAt, shareId: req.shareId, ciphertext: req.ciphertext,
            k: req.k, n: req.n
        )
        return identity.verify(canon, signature: req.senderSignature, publicKey: contact.edPublicKey)
    }

    /// True only if `req`'s recipientSignature verifies against a known contact's Ed25519 key.
    /// Reconstructs the exact bytes the recipient signed: for a Deposit approval the recipient
    /// never supplies ciphertext (the relay returns Alice's), so that case signs over
    /// `ciphertext = nil` even though the row's own ciphertext field is populated for delivery.
    private func verifyRespond(_ req: ShareRequest) -> Bool {
        guard let sig = req.recipientSignature else { return false }
        guard let contact = contactRepository.getByEdKey(req.recipientKey) else { return false }
        let approved = req.state == .approved
        let signedCiphertext = (approved && req.transactionType == .retrieval) ? req.ciphertext : nil
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
            let canon = PayloadCanonical.forOpen(secretId: secretId, transactionType: .deposit, recipientKey: contact.edPublicKey, label: label, secretCreatedAt: createdAt, shareId: nil, ciphertext: ciphertext, k: threshold, n: contacts.count)
            let senderSignature = try identity.sign(canon)
            let req = try await relay(for: contact).openShareRequest(
                secretId: secretId,
                recipientKey: contact.edPublicKey,
                label: label,
                secretCreatedAt: createdAt,
                transactionType: .deposit,
                shareId: nil,
                ciphertext: ciphertext,
                k: threshold,
                n: contacts.count,
                senderSignature: senderSignature
            )
            try? shareMetadataRepository.save(ShareMetadata(id: req.id, secretId: secretId, contactId: contact.id))
        }
        try? secretRepository.save(Secret(id: secretId, label: label, k: threshold, n: contacts.count, secretCreatedAt: createdAt, state: .active))
    }

    public func listSecrets() throws -> [Secret] {
        try secretRepository.getAll()
    }

    public func listDistributed() throws -> [ShareMetadata] {
        try shareMetadataRepository.getAll()
    }

    public func syncDistributed() async throws {
        for relay in allRelays() {
            let reqs = (try? await relay.listShareRequests(role: .sender, transactionType: .deposit, state: nil)) ?? []
            for req in reqs {
                // A row for a holder we no longer have a contact record for can't be re-anchored
                // to a contactId — skip rather than drop the holder's identity on the floor.
                guard let contact = contactRepository.getByEdKey(req.recipientKey) else { continue }
                try? shareMetadataRepository.save(ShareMetadata(id: req.id, secretId: req.secretId, contactId: contact.id))
            }
        }
        await reconcileDiscarding()
    }

    /// For every `.discarding` `Secret`, checks whether each remaining holder's fanned-out
    /// `removal` request has been approved; approved ones are cleaned up (relay row deleted, local
    /// `ShareMetadata` removed). Once a `.discarding` secret has no `ShareMetadata` rows left, its
    /// `Secret` record itself is removed. See item 11's two-state lifecycle.
    private func reconcileDiscarding() async {
        let secrets = (try? secretRepository.getAll()) ?? []
        let discarding = secrets.filter { $0.state == .discarding }
        guard !discarding.isEmpty else { return }
        let discardingIds = Set(discarding.map(\.id))

        var removalRequests: [(relay: any ShareRelay, request: ShareRequest)] = []
        for relay in allRelays() {
            let reqs = (try? await relay.listShareRequests(role: .sender, transactionType: .removal, state: nil)) ?? []
            removalRequests += reqs.filter { discardingIds.contains($0.secretId) }.map { (relay: relay, request: $0) }
        }

        for secret in discarding {
            let metasForSecret = ((try? shareMetadataRepository.getAll()) ?? []).filter { $0.secretId == secret.id }
            for meta in metasForSecret {
                guard let approvedRemoval = removalRequests.first(where: { $0.request.shareId == meta.id && $0.request.state == .approved }) else { continue }
                try? await approvedRemoval.relay.deleteShareRequest(requestId: meta.id)
                try? shareMetadataRepository.delete(shareId: meta.id)
            }
            let remaining = ((try? shareMetadataRepository.getAll()) ?? []).filter { $0.secretId == secret.id }
            if remaining.isEmpty {
                try? secretRepository.delete(secretId: secret.id)
            }
        }
    }

    public func listSentRequests() async throws -> [ShareRequest] {
        var all: [ShareRequest] = []
        for relay in allRelays() {
            all += (try? await relay.listShareRequests(role: .sender, transactionType: nil, state: nil)) ?? []
        }
        return all.filter { $0.transactionType != .deposit }
    }

    public func requestAll(secretId: UUID) async throws {
        guard let secret = (try? secretRepository.getAll())?.first(where: { $0.id == secretId }) else { return }
        let deposited = (try? shareMetadataRepository.getAll()) ?? []
        let forSecret = deposited.filter { $0.secretId == secretId }
        var existing: [ShareRequest] = []
        for relay in allRelays() {
            existing += (try? await relay.listShareRequests(role: .sender, transactionType: .retrieval, state: nil)) ?? []
        }
        for meta in forSecret {
            guard let contact = contactRepository.getById(meta.contactId) else { continue }
            // Matched on secretId, not the local shareId — a recovered ShareMetadata's id is a
            // freshly generated local UUID with no relay-row counterpart. See item 8.
            let hasActive = existing.contains {
                $0.secretId == meta.secretId && ($0.state == .pending || $0.state == .approved)
            }
            if !hasActive {
                let canon = PayloadCanonical.forOpen(secretId: meta.secretId, transactionType: .retrieval, recipientKey: contact.edPublicKey, label: secret.label, secretCreatedAt: secret.secretCreatedAt, shareId: meta.id, ciphertext: nil)
                if let senderSignature = try? identity.sign(canon) {
                    _ = try? await relay(for: contact).openShareRequest(
                        secretId: meta.secretId,
                        recipientKey: contact.edPublicKey,
                        label: secret.label,
                        secretCreatedAt: secret.secretCreatedAt,
                        transactionType: .retrieval,
                        shareId: meta.id,
                        ciphertext: nil,
                        k: nil,
                        n: nil,
                        senderSignature: senderSignature
                    )
                }
            }
        }
    }

    public func openRequest(shareId: UUID, type: ShareTransactionType) async throws -> ShareRequest {
        let all = (try? shareMetadataRepository.getAll()) ?? []
        guard let meta = all.first(where: { $0.id == shareId }) else {
            throw ShareServiceError.shareNotFound
        }
        guard let secret = (try? secretRepository.getAll())?.first(where: { $0.id == meta.secretId }) else {
            throw ShareServiceError.secretNotFound
        }
        guard let contact = contactRepository.getById(meta.contactId) else {
            throw ShareServiceError.contactNotFound
        }
        let canon = PayloadCanonical.forOpen(secretId: meta.secretId, transactionType: type, recipientKey: contact.edPublicKey, label: secret.label, secretCreatedAt: secret.secretCreatedAt, shareId: shareId, ciphertext: nil)
        let senderSignature = try identity.sign(canon)
        return try await relay(for: contact).openShareRequest(
            secretId: meta.secretId,
            recipientKey: contact.edPublicKey,
            label: secret.label,
            secretCreatedAt: secret.secretCreatedAt,
            transactionType: type,
            shareId: shareId,
            ciphertext: nil,
            k: nil,
            n: nil,
            senderSignature: senderSignature
        )
    }

    /// Pure read (item 11): collects and decrypts `k` approved retrieval shares, but never tears
    /// down local `ShareMetadata` or relay rows. Use `discardSecret` for teardown — reconstruct is
    /// now a *step* toward a possible re-split, not an implicit "I'm done with this" signal.
    public func reconstruct(secretId: UUID) async throws -> Data {
        guard let secret = (try? secretRepository.getAll())?.first(where: { $0.id == secretId }) else {
            throw ShareServiceError.secretNotFound
        }
        var allRequests: [(relay: any ShareRelay, request: ShareRequest)] = []
        for relay in allRelays() {
            let reqs = (try? await relay.listShareRequests(role: .sender, transactionType: .retrieval, state: nil)) ?? []
            allRequests += reqs.map { (relay: relay, request: $0) }
        }
        // An unverified recipientSignature is treated as "not yet approved" rather than a hard
        // error — a forged approval simply doesn't count toward the threshold.
        let approved = allRequests.filter { pair in
            pair.request.secretId == secretId && pair.request.state == .approved && pair.request.ciphertext != nil && verifyRespond(pair.request)
        }
        guard approved.count >= secret.k else {
            throw ShareServiceError.notEnoughApprovedShares(have: approved.count, need: secret.k)
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
        return Data(secretBytes)
    }

    /// Fans out a sender-initiated `removal` to every known holder of `secretId` and flips the
    /// `Secret` to `.discarding` immediately, before any holder has responded — see item 11.
    public func discardSecret(secretId: UUID) async throws {
        guard let secret = (try? secretRepository.getAll())?.first(where: { $0.id == secretId }) else {
            throw ShareServiceError.secretNotFound
        }
        try secretRepository.save(Secret(id: secret.id, label: secret.label, k: secret.k, n: secret.n, secretCreatedAt: secret.secretCreatedAt, state: .discarding))
        let shares = ((try? shareMetadataRepository.getAll()) ?? []).filter { $0.secretId == secretId }
        for share in shares {
            _ = try? await openRequest(shareId: share.id, type: .removal)
        }
    }

    /// Local-only teardown for a `.discarding` secret whose holders won't all respond (e.g. a
    /// permanently dark holder) — removes the `Secret` and its remaining `ShareMetadata` rows
    /// without waiting for relay confirmation. See item 11.
    public func forceForgetSecret(secretId: UUID) throws {
        let shares = ((try? shareMetadataRepository.getAll()) ?? []).filter { $0.secretId == secretId }
        for share in shares {
            try? shareMetadataRepository.delete(shareId: share.id)
        }
        try secretRepository.delete(secretId: secretId)
    }

    // MARK: - Recipient flows

    public func syncInbox() async throws {
        for relay in allRelays() {
            let pending = (try? await relay.listShareRequests(role: .recipient, transactionType: .deposit, state: .pending)) ?? []
            // Unknown sender or unverified senderSignature: skip silently, do not auto-approve.
            for req in pending where verifyOpen(req) {
                guard let senderContact = contactRepository.getByEdKey(req.senderKey) else { continue }
                // A deposit without valid k/n can't happen against a conforming relay (required by
                // ShareRequestsService) — skip defensively rather than store a share we can't
                // later report thresholds for during recovery.
                guard let k = req.k, let n = req.n else { continue }
                if shareRepository.getPlaintextShare(secretId: req.secretId) == nil {
                    let canon = PayloadCanonical.forRespond(requestId: req.id, approved: true, ciphertext: nil)
                    guard let recipientSignature = try? identity.sign(canon) else { continue }
                    if let responded = try? await relay.respondToShareRequest(requestId: req.id, approved: true, ciphertext: nil, recipientSignature: recipientSignature),
                       let ct = responded.ciphertext,
                       let plaintext = try? encryption.decrypt(ct, recipientXPublicKey: senderContact.xPublicKey) {
                        shareRepository.save(HeldShare(
                            id: req.id,
                            secretId: req.secretId,
                            label: req.label,
                            contactId: senderContact.id,
                            senderPseudonym: senderContact.pseudonym,
                            createdAt: req.secretCreatedAt,
                            pickedUpAt: Date(),
                            plaintextShare: plaintext,
                            k: k,
                            n: n
                        ))
                    }
                }
            }
        }
        await processRecoveryMetadata()
    }

    /// Identity recovery (item 8) — sender/owner side. Consumes pending `recoveryMetadata` pushes
    /// addressed to this device, rebuilding `Secret`/`ShareMetadata` records from what each holder
    /// reports. A push is trusted only once its `senderSignature` verifies against a *known*
    /// contact — the holder must already have been re-added out-of-band (item 8 step 1) before
    /// their push is honored. Consumed rows are deleted from the relay once processed.
    private func processRecoveryMetadata() async {
        for relay in allRelays() {
            let pushes = (try? await relay.listShareRequests(role: .recipient, transactionType: .inventory, state: .approved)) ?? []
            for req in pushes where verifyOpen(req) {
                guard let holderContact = contactRepository.getByEdKey(req.senderKey) else { continue }
                guard let k = req.k, let n = req.n else { continue }
                let existingSecrets = (try? secretRepository.getAll()) ?? []
                if !existingSecrets.contains(where: { $0.id == req.secretId }) {
                    try? secretRepository.save(Secret(id: req.secretId, label: req.label, k: k, n: n, secretCreatedAt: req.secretCreatedAt, state: .active))
                }
                let existingMeta = (try? shareMetadataRepository.getAll()) ?? []
                if !existingMeta.contains(where: { $0.secretId == req.secretId && $0.contactId == holderContact.id }) {
                    try? shareMetadataRepository.save(ShareMetadata(id: UUID(), secretId: req.secretId, contactId: holderContact.id))
                }
                try? await relay.deleteShareRequest(requestId: req.id)
            }
        }
    }

    public func pushRecoveryMetadata(contactId: UUID) async throws {
        guard let contact = contactRepository.getById(contactId) else {
            throw ShareServiceError.contactNotFound
        }
        let heldFromContact = shareRepository.getAll().filter { $0.contactId == contactId }
        for share in heldFromContact {
            let canon = PayloadCanonical.forOpen(secretId: share.secretId, transactionType: .inventory, recipientKey: contact.edPublicKey, label: share.label, secretCreatedAt: share.createdAt, shareId: nil, ciphertext: nil, k: share.k, n: share.n)
            guard let senderSignature = try? identity.sign(canon) else { continue }
            _ = try? await relay(for: contact).openShareRequest(
                secretId: share.secretId,
                recipientKey: contact.edPublicKey,
                label: share.label,
                secretCreatedAt: share.createdAt,
                transactionType: .inventory,
                shareId: nil,
                ciphertext: nil,
                k: share.k,
                n: share.n,
                senderSignature: senderSignature
            )
        }
    }

    public func listHeld() throws -> [HeldShare] {
        shareRepository.getAll()
    }

    public func listPendingRequests() async throws -> [ShareRequest] {
        var all: [ShareRequest] = []
        for relay in allRelays() {
            all += (try? await relay.listShareRequests(role: .recipient, transactionType: nil, state: .pending)) ?? []
        }
        // A forged removal/retrieval request has no AEAD backstop — must never reach the UI.
        return all.filter { $0.transactionType != .deposit && verifyOpen($0) }
    }

    public func respond(requestId: UUID, approved: Bool) async throws {
        let (relay, request) = try await findShareRequest(requestId)
        guard verifyOpen(request) else {
            throw ShareServiceError.signatureVerificationFailed("senderSignature does not verify for request \(requestId)")
        }
        let ciphertext: Data?
        if approved && request.transactionType == .retrieval {
            // Matched on secretId, not the sender's local shareId — that id is meaningless to
            // this device once identities can be rebuilt independently after recovery (item 8).
            guard let plaintext = shareRepository.getPlaintextShare(secretId: request.secretId) else {
                throw ShareServiceError.shareNotFound
            }
            // Re-encrypt to the requester's *current* X25519 key — looked up live, not pinned at
            // deposit time. This is what lets reconstruction survive a sender key rotation/
            // recovery (item 7's core reason for existing).
            guard let requesterContact = contactRepository.getByEdKey(request.senderKey) else {
                throw ShareServiceError.contactNotFound
            }
            ciphertext = try encryption.encrypt(plaintext, recipientXPublicKey: requesterContact.xPublicKey)
        } else {
            ciphertext = nil
        }
        let canon = PayloadCanonical.forRespond(requestId: requestId, approved: approved, ciphertext: ciphertext)
        let recipientSignature = try identity.sign(canon)
        _ = try await relay.respondToShareRequest(requestId: requestId, approved: approved, ciphertext: ciphertext, recipientSignature: recipientSignature)
        if approved && request.transactionType == .removal {
            if let heldShare = shareRepository.getAll().first(where: { $0.secretId == request.secretId }) {
                shareRepository.delete(shareId: heldShare.id)
            }
        }
    }

    public func deleteHeldShare(shareId: UUID) async throws {
        shareRepository.delete(shareId: shareId)
    }

    public func deleteAllHeldFromSender(contactId: UUID) async throws {
        for share in shareRepository.getAll() where share.contactId == contactId {
            shareRepository.delete(shareId: share.id)
        }
    }
}

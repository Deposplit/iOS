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
    private let contactManagement: any ContactManagement
    private let keyConflictRepository: any KeyConflictRepository
    private let retainedDepositRepository: any RetainedDepositRepository
    private let identity: any Identity

    public init(
        relayResolver: any ShareRelayResolver,
        encryption: any ShareEncryption,
        shareRepository: any ShareRepository,
        shareMetadataRepository: any ShareMetadataRepository,
        secretRepository: any SecretRepository,
        contactRepository: any ContactRepository,
        contactManagement: any ContactManagement,
        keyConflictRepository: any KeyConflictRepository,
        retainedDepositRepository: any RetainedDepositRepository,
        identity: any Identity
    ) {
        self.relayResolver = relayResolver
        self.encryption = encryption
        self.shareRepository = shareRepository
        self.shareMetadataRepository = shareMetadataRepository
        self.secretRepository = secretRepository
        self.contactRepository = contactRepository
        self.contactManagement = contactManagement
        self.keyConflictRepository = keyConflictRepository
        self.retainedDepositRepository = retainedDepositRepository
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
        guard let contact = contactRepository.getByVerifyKey(req.senderKey) else { return false }
        let canon = PayloadCanonical.forOpen(
            secretId: req.secretId, transactionType: req.transactionType, recipientKey: req.recipientKey,
            label: req.label, secretCreatedAt: req.secretCreatedAt, shareId: req.shareId, ciphertext: req.ciphertext,
            k: req.k, n: req.n
        )
        return identity.verify(canon, signature: req.senderSignature, publicKey: contact.verifyKey)
    }

    /// True only if `req`'s recipientSignature verifies against a known contact's Ed25519 key.
    /// Reconstructs the exact bytes the recipient signed: for a Deposit approval the recipient
    /// never supplies ciphertext (the relay returns Alice's), so that case signs over
    /// `ciphertext = nil` even though the row's own ciphertext field is populated for delivery.
    private func verifyRespond(_ req: ShareRequest) -> Bool {
        guard let sig = req.recipientSignature else { return false }
        guard let contact = contactRepository.getByVerifyKey(req.recipientKey) else { return false }
        let approved = req.state == .approved
        let signedCiphertext = (approved && req.transactionType == .retrieval) ? req.ciphertext : nil
        let canon = PayloadCanonical.forRespond(requestId: req.id, approved: approved, ciphertext: signedCiphertext)
        return identity.verify(canon, signature: sig, publicKey: contact.verifyKey)
    }

    // MARK: - Sender flows

    public func deposit(secret: Data, label: String, contacts: [Contact], threshold: Int) async throws {
        let shares = try split(secret: Array(secret), shares: contacts.count, threshold: threshold)
        let secretId = UUID()
        let createdAt = Date()
        for (contact, share) in zip(contacts, shares) {
            let ciphertext = try encryption.encrypt(Data(share), recipientEncKey: contact.encKey)
            let canon = PayloadCanonical.forOpen(secretId: secretId, transactionType: .deposit, recipientKey: contact.verifyKey, label: label, secretCreatedAt: createdAt, shareId: nil, ciphertext: ciphertext, k: threshold, n: contacts.count)
            let senderSignature = try identity.sign(canon)
            let req = try await relay(for: contact).openShareRequest(
                secretId: secretId,
                recipientKey: contact.verifyKey,
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
            // Item 12 — retained until this holder's pickup is confirmed (relay-observed or
            // heartbeat-attested), then discarded. Safe to retain: this blob is encrypted to the
            // holder's X25519 key, so this device cannot decrypt it itself.
            try? retainedDepositRepository.save(RetainedDepositBlob(id: req.id, secretId: secretId, contactId: contact.id, label: label, secretCreatedAt: createdAt, ciphertext: ciphertext, k: threshold, n: contacts.count))
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
        let existingMetadata = (try? shareMetadataRepository.getAll()) ?? []
        for relay in allRelays() {
            let reqs = (try? await relay.listShareRequests(role: .sender, transactionType: .deposit, state: nil)) ?? []
            for req in reqs {
                if req.state == .withdrawn {
                    // Best-effort tombstone (item 9): the holder unilaterally stopped holding
                    // this share. Drop the local pointer so the health count reflects it, then
                    // clean up the relay row — it has served its purpose and needn't linger. Row
                    // *absence* is never itself a signal; only an *observed* withdrawn state
                    // counts, and we've just observed it.
                    try? shareMetadataRepository.delete(shareId: req.id)
                    try? await relay.deleteShareRequest(requestId: req.id)
                    continue
                }
                // A row for a holder we no longer have a contact record for can't be re-anchored
                // to a contactId — skip rather than drop the holder's identity on the floor.
                guard let contact = contactRepository.getByVerifyKey(req.recipientKey) else { continue }
                let priorConfirmedAt = existingMetadata.first(where: { $0.id == req.id })?.lastConfirmedAt
                if req.state == .approved, isRetentionStillPending(req.id) {
                    // Item 12 — first-observed pickup confirmation (relay-observed channel): a
                    // one-time transition, not "still approved therefore still fresh" — an
                    // unchanging Approved row on a later poll must not keep bumping freshness, or
                    // a long-dead holder would look perpetually confirmed. The retained blob's
                    // continued existence is exactly the "not yet confirmed by any channel"
                    // marker, so its presence is what gates the stamp.
                    try? shareMetadataRepository.save(ShareMetadata(id: req.id, secretId: req.secretId, contactId: contact.id, lastConfirmedAt: Date()))
                    try? retainedDepositRepository.delete(id: req.id)
                } else {
                    try? shareMetadataRepository.save(ShareMetadata(id: req.id, secretId: req.secretId, contactId: contact.id, lastConfirmedAt: priorConfirmedAt))
                }
            }
            // Item 12 — a retrieve approval is also proof-of-custody. Polled here purely for that
            // freshness side effect; the functional read path for these rows is reconstruct()/
            // listSentRequests(), unchanged.
            let retrievals = (try? await relay.listShareRequests(role: .sender, transactionType: .retrieval, state: .approved)) ?? []
            for req in retrievals {
                guard let shareId = req.shareId, let meta = existingMetadata.first(where: { $0.id == shareId }) else { continue }
                try? shareMetadataRepository.save(ShareMetadata(id: meta.id, secretId: meta.secretId, contactId: meta.contactId, lastConfirmedAt: Date()))
            }
        }
        await reconcileDiscarding()
        await processHeartbeats()
    }

    private func isRetentionStillPending(_ depositId: UUID) -> Bool {
        ((try? retainedDepositRepository.getAll()) ?? []).contains(where: { $0.id == depositId })
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

    // Item 13 — a holder is worth prioritizing for a fresh retrieval ask when item 12's own
    // "still counts toward n_live" freshness rule already trusts them: an unexpired
    // proof-of-custody and no standing opt-out. Recomputed here (not shared with the UI layer's
    // own FreshnessBucket, which serves display, not targeting) — a small, deliberate duplication
    // of a threshold check rather than restructuring already-shipped item-12 UI code.
    private func isConfirmed(_ meta: ShareMetadata) -> Bool {
        guard let contact = contactRepository.getById(meta.contactId), contact.heartbeatOptedOutAt == nil,
            let lastConfirmedAt = meta.lastConfirmedAt else { return false }
        return Date().timeIntervalSince(lastConfirmedAt) <= CustodyHeartbeatTuning.lossThreshold
    }

    public func requestAll(secretId: UUID) async throws {
        guard let secret = (try? secretRepository.getAll())?.first(where: { $0.id == secretId }) else { return }
        let deposited = (try? shareMetadataRepository.getAll()) ?? []
        let forSecret = deposited.filter { $0.secretId == secretId }
        var existing: [ShareRequest] = []
        for relay in allRelays() {
            existing += (try? await relay.listShareRequests(role: .sender, transactionType: .retrieval, state: nil)) ?? []
        }
        // Item 13 — fan out to the health-informed fresh set first; widen to everyone only when
        // there aren't enough confirmed holders to reach k. A retrieval request exists solely to
        // feed an eventual reconstruct(), so this targeting applies here rather than as a
        // separate method.
        let confirmed = forSecret.filter(isConfirmed)
        let targets = confirmed.count >= secret.k ? confirmed : forSecret
        for meta in targets {
            guard let contact = contactRepository.getById(meta.contactId) else { continue }
            // Matched on secretId plus the holder's key. Not the local shareId — a recovered
            // ShareMetadata's id is a freshly generated local UUID with no relay-row counterpart
            // (see item 8). And not secretId alone — every holder of a secret shares it, so one
            // standing row would silence the whole fan-out. A holder who rotated keys since the
            // row was opened no longer matches, which is right: that row is unreachable under
            // the new key anyway.
            let hasActive = existing.contains {
                $0.secretId == meta.secretId && $0.recipientKey == contact.verifyKey
                    && ($0.state == .pending || $0.state == .approved)
            }
            if !hasActive {
                let canon = PayloadCanonical.forOpen(secretId: meta.secretId, transactionType: .retrieval, recipientKey: contact.verifyKey, label: secret.label, secretCreatedAt: secret.secretCreatedAt, shareId: meta.id, ciphertext: nil)
                if let senderSignature = try? identity.sign(canon) {
                    _ = try? await relay(for: contact).openShareRequest(
                        secretId: meta.secretId,
                        recipientKey: contact.verifyKey,
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
        let canon = PayloadCanonical.forOpen(secretId: meta.secretId, transactionType: type, recipientKey: contact.verifyKey, label: secret.label, secretCreatedAt: secret.secretCreatedAt, shareId: shareId, ciphertext: nil)
        let senderSignature = try identity.sign(canon)
        return try await relay(for: contact).openShareRequest(
            secretId: meta.secretId,
            recipientKey: contact.verifyKey,
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
    public func reconstruct(secretId: UUID) async throws -> ReconstructionResult {
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
        // Item 13 — each decrypted share is kept paired with its originating contact so an
        // excluded index (from combineWithIntegrity) reports back as a suspect contact, not a
        // meaningless array position.
        var decryptedShares: [[UInt8]] = []
        var contactIds: [UUID] = []
        for pair in approved {
            let ct = pair.request.ciphertext!
            guard let contact = contactRepository.getByVerifyKey(pair.request.recipientKey) else {
                throw ShareServiceError.contactNotFound
            }
            let plaintext = try encryption.decrypt(ct, recipientEncKey: contact.encKey)
            decryptedShares.append(Array(plaintext))
            contactIds.append(contact.id)
        }
        let result = try combineWithIntegrity(shares: decryptedShares, threshold: secret.k)
        let integrity: ReconstructionIntegrity
        if !result.hasIntegrityMargin {
            integrity = .noMargin
        } else if result.excludedIndices.isEmpty {
            integrity = .confirmed
        } else {
            integrity = .excludedSuspects(excludedContactIds: Set(result.excludedIndices.map { contactIds[$0] }))
        }
        return ReconstructionResult(secret: Data(result.secret), integrity: integrity)
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
                guard let senderContact = contactRepository.getByVerifyKey(req.senderKey) else { continue }
                // A deposit without valid k/n can't happen against a conforming relay (required by
                // ShareRequestsService) — skip defensively rather than store a share we can't
                // later report thresholds for during recovery.
                guard let k = req.k, let n = req.n else { continue }
                if shareRepository.getPlaintextShare(secretId: req.secretId) == nil {
                    let canon = PayloadCanonical.forRespond(requestId: req.id, approved: true, ciphertext: nil)
                    guard let recipientSignature = try? identity.sign(canon) else { continue }
                    if let responded = try? await relay.respondToShareRequest(requestId: req.id, approved: true, ciphertext: nil, recipientSignature: recipientSignature),
                       let ct = responded.ciphertext,
                       let plaintext = try? encryption.decrypt(ct, recipientEncKey: senderContact.encKey) {
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
        await processRotations()
        await emitHeartbeats()
    }

    /// Item 12, holder side — opportunistically piggybacks this same inbox poll: for each
    /// distinct sender this device currently holds at least one share from, pushes one coalesced
    /// heartbeat (or opt-out notice) once the per-sender emission interval has elapsed. Each push
    /// is independently best-effort so one unreachable BYOR relay doesn't block heartbeating
    /// other senders. `lastHeartbeatSentAt` only advances on a *successful* push, so a transient
    /// failure retries on the very next poll rather than waiting out the full interval again.
    private func emitHeartbeats() async {
        let held = shareRepository.getAll()
        let senderIds = Set(held.map(\.contactId))
        let now = Date()
        for contactId in senderIds {
            guard let contact = contactRepository.getById(contactId) else { continue }
            let dueSince = contact.lastHeartbeatSentAt.map { now.timeIntervalSince($0) } ?? .infinity
            guard dueSince >= CustodyHeartbeatTuning.emissionInterval else { continue }
            let secretIds = contact.heartbeatEmissionOptedOut ? [] : held.filter { $0.contactId == contactId }.map(\.secretId)
            let canon = PayloadCanonical.forHeartbeat(ownerKey: contact.verifyKey, secretIds: secretIds, optedOut: contact.heartbeatEmissionOptedOut)
            guard let signature = try? identity.sign(canon) else { continue }
            do {
                try await relay(for: contact).pushHeartbeat(ownerKey: contact.verifyKey, secretIds: secretIds, optedOut: contact.heartbeatEmissionOptedOut, signature: signature)
            } catch {
                continue
            }
            contactRepository.save(Contact(
                id: contact.id, pseudonym: contact.pseudonym, verifyKey: contact.verifyKey, encKey: contact.encKey,
                verificationLevel: contact.verificationLevel, verifiedAt: contact.verifiedAt, addedAt: contact.addedAt,
                relayBaseUrl: contact.relayBaseUrl, revokedVerifyKeys: contact.revokedVerifyKeys, keyChangedAt: contact.keyChangedAt,
                heartbeatOptedOutAt: contact.heartbeatOptedOutAt, lastHeartbeatSentAt: now, heartbeatEmissionOptedOut: contact.heartbeatEmissionOptedOut,
                cipherSuite: contact.cipherSuite, nickname: contact.nickname
            ))
        }
    }

    /// Item 12, owner side — auto-verifies each holder's latest heartbeat (or opt-out notice)
    /// against a known contact's trusted key, then updates local freshness/opt-out state. Never
    /// deletes a heartbeat row — see `CustodyHeartbeat` for why it's a standing status, not a
    /// one-shot delivery. Unknown senders and forged signatures are silently skipped, same
    /// posture as `processRotations()`.
    private func processHeartbeats() async {
        let myKey = identity.verifyKey
        let existingMetadata = (try? shareMetadataRepository.getAll()) ?? []
        for relay in allRelays() {
            let notices = (try? await relay.listHeartbeats()) ?? []
            for notice in notices {
                guard let contact = contactRepository.getByVerifyKey(notice.holderKey) else { continue }
                let canon = PayloadCanonical.forHeartbeat(ownerKey: myKey, secretIds: notice.secretIds, optedOut: notice.optedOut)
                guard identity.verify(canon, signature: notice.signature, publicKey: notice.holderKey) else { continue }
                if notice.optedOut {
                    contactRepository.save(Contact(
                        id: contact.id, pseudonym: contact.pseudonym, verifyKey: contact.verifyKey, encKey: contact.encKey,
                        verificationLevel: contact.verificationLevel, verifiedAt: contact.verifiedAt, addedAt: contact.addedAt,
                        relayBaseUrl: contact.relayBaseUrl, revokedVerifyKeys: contact.revokedVerifyKeys, keyChangedAt: contact.keyChangedAt,
                        heartbeatOptedOutAt: notice.createdAt, lastHeartbeatSentAt: contact.lastHeartbeatSentAt, heartbeatEmissionOptedOut: contact.heartbeatEmissionOptedOut,
                        cipherSuite: contact.cipherSuite, nickname: contact.nickname
                    ))
                    continue
                }
                if contact.heartbeatOptedOutAt != nil {
                    contactRepository.save(Contact(
                        id: contact.id, pseudonym: contact.pseudonym, verifyKey: contact.verifyKey, encKey: contact.encKey,
                        verificationLevel: contact.verificationLevel, verifiedAt: contact.verifiedAt, addedAt: contact.addedAt,
                        relayBaseUrl: contact.relayBaseUrl, revokedVerifyKeys: contact.revokedVerifyKeys, keyChangedAt: contact.keyChangedAt,
                        heartbeatOptedOutAt: nil, lastHeartbeatSentAt: contact.lastHeartbeatSentAt, heartbeatEmissionOptedOut: contact.heartbeatEmissionOptedOut,
                        cipherSuite: contact.cipherSuite, nickname: contact.nickname
                    ))
                }
                for secretId in notice.secretIds {
                    guard let meta = existingMetadata.first(where: { $0.secretId == secretId && $0.contactId == contact.id }) else { continue }
                    try? shareMetadataRepository.save(ShareMetadata(id: meta.id, secretId: meta.secretId, contactId: meta.contactId, lastConfirmedAt: notice.createdAt))
                    if isRetentionStillPending(meta.id) {
                        try? retainedDepositRepository.delete(id: meta.id)
                    }
                }
            }
        }
    }

    public func setHeartbeatEmissionOptedOut(contactId: UUID, optedOut: Bool) throws {
        guard let contact = contactRepository.getById(contactId) else {
            throw ShareServiceError.contactNotFound
        }
        contactRepository.save(Contact(
            id: contact.id, pseudonym: contact.pseudonym, verifyKey: contact.verifyKey, encKey: contact.encKey,
            verificationLevel: contact.verificationLevel, verifiedAt: contact.verifiedAt, addedAt: contact.addedAt,
            relayBaseUrl: contact.relayBaseUrl, revokedVerifyKeys: contact.revokedVerifyKeys, keyChangedAt: contact.keyChangedAt,
            // Reset so the changed preference reaches the contact on the very next poll rather
            // than waiting out the emission interval.
            heartbeatOptedOutAt: contact.heartbeatOptedOutAt, lastHeartbeatSentAt: nil, heartbeatEmissionOptedOut: optedOut,
            cipherSuite: contact.cipherSuite, nickname: contact.nickname
        ))
    }

    /// Item 9, receiving side — auto-verifies a signed rotation notice against the trusted old
    /// key already on file for a known contact, downgrades the verification level to at most
    /// `.low` per item 10's unifying rule (a signed rotation proves continuity of key control,
    /// not a fresh personhood check, so it can never carry a higher level forward), and updates
    /// the contact record in place, preserving `contactId`. Unknown senders and
    /// forged/mismatched signatures are silently skipped — a stranger's notice must never mutate
    /// a real contact.
    private func processRotations() async {
        for relay in allRelays() {
            let notices = (try? await relay.listRotations()) ?? []
            for notice in notices {
                guard let contact = contactRepository.getByVerifyKey(notice.oldVerifyKey) else { continue }
                let canon = PayloadCanonical.forRotation(recipientKey: notice.recipientKey, newVerifyKey: notice.newVerifyKey, newEncKey: notice.newEncKey, newCipherSuite: notice.newCipherSuite)
                guard identity.verify(canon, signature: notice.signature, publicKey: notice.oldVerifyKey) else { continue }
                // Item 10 — a stolen key can't revoke itself, but a locally-flagged one blocks
                // auto-accept here: capture the offer as a conflict for manual resolution instead
                // of trusting a signature the attacker is fully capable of producing. Captured
                // locally *before* deleting the relay row — the relay is best-effort and may GC
                // the notice before anyone looks, but this KeyConflict record won't.
                guard !contact.revokedVerifyKeys.contains(notice.oldVerifyKey) else {
                    try? keyConflictRepository.save(KeyConflict(
                        id: UUID(), contactId: contact.id, oldVerifyKey: notice.oldVerifyKey,
                        newVerifyKey: notice.newVerifyKey, newEncKey: notice.newEncKey, detectedAt: Date()
                    ))
                    try? await relay.deleteRotation(id: notice.id)
                    continue
                }
                // Item 14 — a cipher-suite-only change is likewise "continuity of key control, not
                // a personhood assurance," so it downgrades exactly like a plain key rotation.
                let downgraded = min(contact.verificationLevel, .low)
                try? contactManagement.updateContact(contactId: contact.id, verifyKey: notice.newVerifyKey, encKey: notice.newEncKey, newCipherSuite: notice.newCipherSuite, verificationLevel: downgraded)
                try? await relay.deleteRotation(id: notice.id)
            }
        }
    }

    public func listKeyConflicts() throws -> [KeyConflict] {
        try keyConflictRepository.getAll()
    }

    public func dismissKeyConflict(id: UUID) throws {
        try keyConflictRepository.delete(id: id)
    }

    /// Item 9, sending side (client primitive only — see `ShareManagement.pushRotation`). Signs
    /// the new keys with the device's *current* identity, which becomes `oldVerifyKey` on the
    /// wire, proving continuity of key control to the recipient.
    public func pushRotation(contactId: UUID, newVerifyKey: Data, newEncKey: Data, newCipherSuite: CipherSuite) async throws {
        guard let contact = contactRepository.getById(contactId) else {
            throw ShareServiceError.contactNotFound
        }
        let canon = PayloadCanonical.forRotation(recipientKey: contact.verifyKey, newVerifyKey: newVerifyKey, newEncKey: newEncKey, newCipherSuite: newCipherSuite)
        let signature = try identity.sign(canon)
        try await relay(for: contact).pushRotation(recipientKey: contact.verifyKey, newVerifyKey: newVerifyKey, newEncKey: newEncKey, newCipherSuite: newCipherSuite, signature: signature)
    }

    /// Item 9's identity-regen trigger. Order matters: the drain and the rotation pushes must both
    /// happen *before* `activateKeyPair`, since `pushRotation` (and the drain's own relay calls)
    /// sign with whatever identity is currently persisted — that's what proves continuity from the
    /// old key to each contact. If the app dies partway through, the old identity is still active
    /// (nothing was persisted yet), so a retry simply regenerates and re-pushes from scratch; any
    /// contact who received an orphaned first attempt auto-corrects on the next successful push,
    /// per item 9's existing `K_old`-signed auto-accept rule.
    public func regenerateIdentity() async throws -> RegenerateIdentityResult {
        try? await syncInbox()
        try? await syncDistributed()
        let newKeys = identity.generateNewKeyPair()
        let contacts = contactRepository.getAll()
        var notified = 0
        for contact in contacts {
            do {
                try await pushRotation(contactId: contact.id, newVerifyKey: newKeys.verifyKey, newEncKey: newKeys.encKey, newCipherSuite: .current)
                notified += 1
            } catch {
                // Best-effort — see the type's doc comment; no retry mechanism.
            }
        }
        try identity.activateKeyPair(newKeys)
        return RegenerateIdentityResult(notifiedContacts: notified, totalContacts: contacts.count)
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
                guard let holderContact = contactRepository.getByVerifyKey(req.senderKey) else { continue }
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
            let canon = PayloadCanonical.forOpen(secretId: share.secretId, transactionType: .inventory, recipientKey: contact.verifyKey, label: share.label, secretCreatedAt: share.createdAt, shareId: nil, ciphertext: nil, k: share.k, n: share.n)
            guard let senderSignature = try? identity.sign(canon) else { continue }
            _ = try? await relay(for: contact).openShareRequest(
                secretId: share.secretId,
                recipientKey: contact.verifyKey,
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
            guard let requesterContact = contactRepository.getByVerifyKey(request.senderKey) else {
                throw ShareServiceError.contactNotFound
            }
            ciphertext = try encryption.encrypt(plaintext, recipientEncKey: requesterContact.encKey)
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

    /// Unilateral, no approval needed — but as of item 9 not purely silent: best-effort notifies
    /// the sender via a withdraw tombstone before the local record is dropped, so a courtesy
    /// notice is attempted even if this method throws or the network call fails. The relay call
    /// is fire-and-forget; local deletion always proceeds regardless of its outcome.
    public func deleteHeldShare(shareId: UUID) async throws {
        if let share = shareRepository.getAll().first(where: { $0.id == shareId }),
           let senderContact = contactRepository.getById(share.contactId) {
            try? await relay(for: senderContact).withdrawShareRequests(senderKey: nil, secretId: share.secretId)
        }
        shareRepository.delete(shareId: shareId)
    }

    /// Same best-effort withdraw-tombstone courtesy as `deleteHeldShare`, but scoped to every
    /// share from `contactId` in one relay call (`senderKey`) rather than one per secretId.
    public func deleteAllHeldFromSender(contactId: UUID) async throws {
        if let senderContact = contactRepository.getById(contactId) {
            try? await relay(for: senderContact).withdrawShareRequests(senderKey: senderContact.verifyKey, secretId: nil)
        }
        for share in shareRepository.getAll() where share.contactId == contactId {
            shareRepository.delete(shareId: share.id)
        }
    }
}

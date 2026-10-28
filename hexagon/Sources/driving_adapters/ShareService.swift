import Foundation

public enum ShareServiceError: Error, LocalizedError {
    case contactNotFound
    case shareNotFound
    case secretNotFound
    case notEnoughApprovedShares(have: Int, need: Int)
    case signatureVerificationFailed(String)
    case shareRequestNotFoundOnAnyRelay(UUID)
    /// Carries the numbers rather than a sentence, so a caller can say what happened in its own
    /// language — `errorDescription` here is not localised.
    case secretTooLarge(bytes: Int, limit: Int)
    /// Likewise numbers rather than a sentence, so a paywall can show how full the free tier is
    /// without counting again.
    case freeTierLimitReached(active: Int, limit: Int)
    public var errorDescription: String? {
        switch self {
        case .contactNotFound: "Contact not found — cannot decrypt share."
        case .shareNotFound: "No local share record found."
        case .secretNotFound: "No local record for this secret."
        case .notEnoughApprovedShares(let have, let need): "Need at least \(need) approved shares (have \(have))."
        case .signatureVerificationFailed(let detail): "Signature verification failed: \(detail)"
        case .shareRequestNotFoundOnAnyRelay(let id): "Share request \(id) not found on any known relay."
        case .secretTooLarge(let bytes, let limit): "Secret is \(bytes) bytes; the limit is \(limit)."
        case .freeTierLimitReached(let active, let limit): "\(active) of \(limit) free secrets are already active."
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
    private let identity: any Identity
    private let purchases: any PurchaseRepository

    public init(
        relayResolver: any ShareRelayResolver,
        encryption: any ShareEncryption,
        shareRepository: any ShareRepository,
        shareMetadataRepository: any ShareMetadataRepository,
        secretRepository: any SecretRepository,
        contactRepository: any ContactRepository,
        contactManagement: any ContactManagement,
        keyConflictRepository: any KeyConflictRepository,
        identity: any Identity,
        purchases: any PurchaseRepository
    ) {
        self.relayResolver = relayResolver
        self.encryption = encryption
        self.shareRepository = shareRepository
        self.shareMetadataRepository = shareMetadataRepository
        self.secretRepository = secretRepository
        self.contactRepository = contactRepository
        self.contactManagement = contactManagement
        self.keyConflictRepository = keyConflictRepository
        self.identity = identity
        self.purchases = purchases
    }

    // MARK: - Relay resolution

    /// Every distinct relay referenced across the contact list, plus the default — used by
    /// fan-out methods (syncInbox, listPendingRequests, syncDistributed, listSentRequests) since
    /// a device has no other way to know in advance which relay a given contact's pending item
    /// lives on. Each relay call is independently soft-failed so one unreachable BYOR relay
    /// doesn't blank out results from the default relay or others — and recorded by `fromRelay`,
    /// so that it does not go unnoticed either.
    ///
    /// Resolve first, then dedupe: `nil` and a contact pinned to this device's own default relay
    /// are two names for one relay, and only the resolver knows that. Deduping the overrides
    /// instead leaves the same relay in the list twice, so every row is seen twice — which
    /// reconstruct cannot survive, since it then combines each share twice and fails on duplicate
    /// x-coordinates.
    private func allRelays() -> [any ShareRelay] {
        var seen = Set<ObjectIdentifier>()
        return (contactRepository.getAll().map { $0.relayBaseUrl } + [nil])
            .map { relayResolver.resolve($0) }
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func relay(for contact: Contact) -> any ShareRelay {
        relayResolver.resolve(contact.relayBaseUrl)
    }

    /// The relays one pass or one fan-out could not read, by base URL: those that did not answer,
    /// and those that answered with an error, with the status they gave. A relay is named once.
    /// When it refused one listing and went silent on another, the refusal wins, because it proves
    /// the relay is there and its status says why.
    private struct RelayFailures {
        private(set) var unreachable = Set<String>()
        private(set) var refusing: [String: Int] = [:]

        var count: Int { unreachable.count + refusing.count }

        mutating func noteSilent(_ baseUrl: String) {
            if refusing[baseUrl] == nil { unreachable.insert(baseUrl) }
        }

        mutating func noteRefused(_ baseUrl: String, statusCode: Int) {
            unreachable.remove(baseUrl)
            if refusing[baseUrl] == nil { refusing[baseUrl] = statusCode }
        }

        mutating func merge<T>(_ fanOut: RelayFanOut<T>) {
            fanOut.unreachableRelays.forEach { noteSilent($0) }
            fanOut.refusingRelays.forEach { noteRefused($0.key, statusCode: $0.value) }
        }

        var report: SyncReport { SyncReport(unreachableRelays: unreachable, refusingRelays: refusing) }
    }

    /// One listing against one relay. A relay that fails contributes nothing and is noted in
    /// `failures` by its base URL, which is how a sync pass or a fan-out read reports it. Only
    /// listings go through here: whether a relay answers is a question about the relay, whereas a
    /// failure acting on one row is about that row.
    ///
    /// A relay that has already gone silent in this pass is not asked again. Every further ask would
    /// wait out the same timeout and learn nothing new, and a pass makes several, so a relay that is
    /// down would otherwise hold the whole pass up for one timeout per listing. One that refused is
    /// still asked: it answers at once, and it is there.
    private func fromRelay<T>(_ relay: any ShareRelay, _ failures: inout RelayFailures, _ listing: () async throws -> [T]) async -> [T] {
        guard !failures.unreachable.contains(relay.baseUrl) else { return [] }
        do {
            return try await listing()
        } catch RelayError.refused(let statusCode, _) {
            failures.noteRefused(relay.baseUrl, statusCode: statusCode)
            return []
        } catch {
            failures.noteSilent(relay.baseUrl)
            return []
        }
    }

    /// Every row this device is a party to, from every relay it knows, listed once — each paired
    /// with the relay it was found on, so a caller can act on it through that same one.
    ///
    /// Deduplicated by request id, because `allRelays()` can only deduplicate by *name* and one
    /// relay answers to several: a contact pinned to `http://127.0.0.1:9000` while this device's
    /// own default says `http://localhost:9000` is one host under two names, and nothing short of
    /// asking the relay could tell. The rows settle it instead — a request id is minted by the
    /// relay that holds the row, so two rows sharing one are one row seen twice.
    ///
    /// This is not only about a list showing an entry twice. Reconstruct would collect each
    /// approved share twice, decrypt both copies, and hand the combiner duplicate x-coordinates,
    /// which it rightly refuses.
    ///
    /// `silent` names the relays a calling sync pass has already heard nothing from. They are not
    /// asked again, and are reported unreachable all the same.
    private func rowsAcrossRelays(role: Role, transactionType: ShareTransactionType? = nil, state: ShareRequestState? = nil, silent: Set<String> = []) async -> RelayFanOut<(relay: any ShareRelay, request: ShareRequest)> {
        var rows: [(relay: any ShareRelay, request: ShareRequest)] = []
        var seen = Set<UUID>()
        var failures = RelayFailures()
        silent.forEach { failures.noteSilent($0) }
        let relays = allRelays()
        for relay in relays {
            let found = await fromRelay(relay, &failures) {
                try await relay.listShareRequests(role: role, transactionType: transactionType, state: state)
            }
            for request in found where seen.insert(request.id).inserted {
                rows.append((relay: relay, request: request))
            }
        }
        return RelayFanOut(items: rows, unreachableRelays: failures.unreachable, refusingRelays: failures.refusing, anyAnswered: failures.count < relays.count)
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
            sealedLabel: req.sealedLabel, secretCreatedAt: req.secretCreatedAt, ciphertext: req.ciphertext,
            k: req.k, n: req.n, mimeType: req.mimeType
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

    public func deposit(secret: Data, label: String, contacts: [Contact], threshold: Int, mimeType: MimeType = .default, replacing: UUID? = nil) async throws {
        guard secret.count <= SecretLimits.maxSecretBytes else {
            throw ShareServiceError.secretTooLarge(bytes: secret.count, limit: SecretLimits.maxSecretBytes)
        }
        // The free tier is counted here rather than at the form so that no entry point can slip
        // past it, exactly as the size limit above is. A repair passes `replacing` and is exempt: it
        // supersedes an active secret instead of adding a fourth.
        if replacing == nil, !purchases.isPremium() {
            let active = ((try? secretRepository.getAll()) ?? []).filter { $0.state == .active }.count
            guard active < SecretLimits.freeTierMaxActiveSecrets else {
                throw ShareServiceError.freeTierLimitReached(active: active, limit: SecretLimits.freeTierMaxActiveSecrets)
            }
        }
        let shares = try split(secret: Array(secret), shares: contacts.count, threshold: threshold)
        let secretId = UUID()
        let createdAt = Date()
        for (contact, share) in zip(contacts, shares) {
            let ciphertext = try encryption.encrypt(Data(share), recipientEncKey: contact.encKey)
            let sealedLabel = try encryption.sealLabel(label, recipientEncKey: contact.encKey)
            let canon = PayloadCanonical.forOpen(secretId: secretId, transactionType: .deposit, recipientKey: contact.verifyKey, sealedLabel: sealedLabel, secretCreatedAt: createdAt, ciphertext: ciphertext, k: threshold, n: contacts.count, mimeType: mimeType)
            let senderSignature = try identity.sign(canon)
            let req = try await relay(for: contact).openShareRequest(
                secretId: secretId,
                recipientKey: contact.verifyKey,
                sealedLabel: sealedLabel,
                secretCreatedAt: createdAt,
                transactionType: .deposit,
                ciphertext: ciphertext,
                k: threshold,
                n: contacts.count,
                mimeType: mimeType,
                senderSignature: senderSignature
            )
            try? shareMetadataRepository.save(ShareMetadata(id: req.id, secretId: secretId, contactId: contact.id))
        }
        try? secretRepository.save(Secret(id: secretId, label: label, mimeType: mimeType, k: threshold, n: contacts.count, secretCreatedAt: createdAt, state: .active))
    }

    public func listSecrets() throws -> [Secret] {
        try secretRepository.getAll()
    }

    public func listDistributed() throws -> [ShareMetadata] {
        try shareMetadataRepository.getAll()
    }

    @discardableResult
    public func syncDistributed() async throws -> SyncReport {
        let existingMetadata = (try? shareMetadataRepository.getAll()) ?? []
        var failures = RelayFailures()
        let now = Date()
        for relay in allRelays() {
            let reqs = await fromRelay(relay, &failures) {
                try await relay.listShareRequests(role: .sender, transactionType: .deposit, state: nil)
            }
            for req in reqs {
                if req.state == .approved {
                    // The pickup, seen (relay-observed channel). Only a record that exists is
                    // touched: a withdrawal may have dropped this holder since, and a row whose
                    // deletion failed on an earlier pass must not bring them back. Matched by id,
                    // which is the request id.
                    if verifyRespond(req), let meta = existingMetadata.first(where: { $0.id == req.id }) {
                        confirmFromApproval(metaId: meta.id, approval: req, now: now)
                    }
                    // Then the row goes, whether or not it verified. It was a message, and it has
                    // been read: keeping it would leave the relay holding a record of who keeps
                    // what for whom for as long as the share is held.
                    try? await relay.deleteShareRequest(requestId: req.id)
                    continue
                }
                // A row for a holder we no longer have a contact record for can't be re-anchored
                // to a contactId — skip rather than drop the holder's identity on the floor.
                guard let contact = contactRepository.getByVerifyKey(req.recipientKey) else { continue }
                let priorConfirmedAt = existingMetadata.first(where: { $0.id == req.id })?.lastConfirmedAt
                try? shareMetadataRepository.save(ShareMetadata(id: req.id, secretId: req.secretId, contactId: contact.id, lastConfirmedAt: priorConfirmedAt))
            }
            // A retrieve approval is also proof-of-custody. Polled here purely for that
            // freshness side effect; the functional read path for these rows is reconstruct()/
            // listSentRequests(), unchanged.
            let retrievals = await fromRelay(relay, &failures) {
                try await relay.listShareRequests(role: .sender, transactionType: .retrieval, state: .approved)
            }
            for req in retrievals.filter(verifyRespond) {
                // Matched on secretId plus the holder's key, the same pair requestRetrieval fans
                // out on — the row itself carries no pointer back to this device's records, and
                // needs none.
                guard let contact = contactRepository.getByVerifyKey(req.recipientKey),
                      let meta = existingMetadata.first(where: { $0.secretId == req.secretId && $0.contactId == contact.id })
                else { continue }
                confirmFromApproval(metaId: meta.id, approval: req, now: now)
            }
        }
        await processWithdrawals(&failures)
        await reconcileRemovals(&failures)
        await processHeartbeats(&failures)
        return failures.report
    }

    /// An approval is proof of custody only once the holder's signature on it verifies, and it is
    /// dated by when the holder answered, never by when this device happened to read it — so an
    /// approved retrieval read on every pass until its copy is cleared refreshes nothing after the
    /// first, and a row whose deletion failed changes nothing either. Like a heartbeat it only ever
    /// moves the clock forward, and never past this device's own clock.
    ///
    /// Two limits. The answer's time is the relay's, and unsigned: a relay can no longer invent an
    /// approval, but it can re-date a real one, which only a signed time would prevent. And an
    /// approval signed under a key the holder has since rotated away from no longer verifies,
    /// because a contact keeps no previous keys — their next heartbeat confirms them instead.
    ///
    /// Reads the record afresh rather than from the pass's snapshot, so two approvals for one
    /// holder in the same pass cannot undo each other.
    private func confirmFromApproval(metaId: UUID, approval: ShareRequest, now: Date) {
        guard let respondedAt = approval.respondedAt,
              let meta = ((try? shareMetadataRepository.getAll()) ?? []).first(where: { $0.id == metaId })
        else { return }
        let answeredAt = min(respondedAt, now)
        if meta.lastConfirmedAt.map({ $0 < answeredAt }) ?? true {
            try? shareMetadataRepository.save(ShareMetadata(id: meta.id, secretId: meta.secretId, contactId: meta.contactId, lastConfirmedAt: answeredAt))
        }
    }

    /// Drops each holder who has told this device, signed, that they stopped holding a share. Runs
    /// before `reconcileRemovals`, whose trailing clean-up then ends a `.destroying` secret this
    /// has emptied.
    ///
    /// Only a withdrawal that verifies against a known contact counts. The relay cannot sign one,
    /// so it cannot make this device forget a holder who still has the share — the same reason an
    /// approved removal is checked. The notice is explicit rather than read off a heartbeat that
    /// stopped naming the secret: a missing entry is no act, an opted-out holder names nothing,
    /// and a holder who drops their last share from this owner sends no heartbeat at all.
    ///
    /// Along with the record go this device's own asks to that holder about that share, answered
    /// or not, since none of them can come to anything now. An approved retrieval stays: that copy
    /// was handed back before the share was dropped, and is as good as it was.
    private func processWithdrawals(_ failures: inout RelayFailures) async {
        var outstanding: [(relay: any ShareRelay, request: ShareRequest)]?
        for relay in allRelays() {
            let withdrawals = await fromRelay(relay, &failures) {
                try await relay.listShareRequests(role: .recipient, transactionType: .withdrawal, state: nil)
            }
            for req in withdrawals where verifyOpen(req) {
                guard let holder = contactRepository.getByVerifyKey(req.senderKey) else { continue }
                noteRelinked(holder)
                let dropped = ((try? shareMetadataRepository.getAll()) ?? []).filter {
                    $0.secretId == req.secretId && $0.contactId == holder.id
                }
                for meta in dropped {
                    try? shareMetadataRepository.delete(shareId: meta.id)
                }
                if outstanding == nil {
                    outstanding = await rowsAcrossRelays(role: .sender, silent: failures.unreachable).items
                }
                let moot = (outstanding ?? []).filter {
                    $0.request.secretId == req.secretId && $0.request.recipientKey == holder.verifyKey
                        && ($0.request.transactionType == .removal
                            || ($0.request.transactionType == .retrieval && $0.request.state != .approved))
                }
                for row in moot {
                    try? await row.relay.deleteShareRequest(requestId: row.request.id)
                }
                try? await relay.deleteShareRequest(requestId: req.id)
            }
        }
    }

    /// Drops every holder whose `removal` request has come back approved, whatever state the secret
    /// is in: one holder removed from an active secret just as much as each holder of a
    /// `.destroying` one. Approved ones are cleaned up (local `ShareMetadata` removed, then the relay
    /// row). Once a `.destroying` secret has no `ShareMetadata` rows left, its `Secret` record itself
    /// is removed — the Active/Destroying two-state lifecycle.
    ///
    /// The approved removal row is the only thing that ever says a holder destroyed their piece.
    /// Approving it makes the relay sweep the rest of that holder's rows for this secret, the
    /// deposit included, so there is nothing else left to read and an absence would say nothing.
    /// It is read for active secrets too, because otherwise a holder removed from one would be
    /// believed in for good, and asked for their piece again on every retrieval.
    /// The signature is checked for the same reason it is checked on a retrieval approval: a relay
    /// that could forge one could make this device forget a share that is still out there.
    private func reconcileRemovals(_ failures: inout RelayFailures) async {
        let metas = (try? shareMetadataRepository.getAll()) ?? []
        if !metas.isEmpty {
            let secretIds = Set(metas.map(\.secretId))
            let fanOut = await rowsAcrossRelays(role: .sender, transactionType: .removal, silent: failures.unreachable)
            failures.merge(fanOut)
            let removalRequests = fanOut.items
                .filter { secretIds.contains($0.request.secretId) }

            for meta in metas {
                guard let contact = contactRepository.getById(meta.contactId),
                      let approvedRemoval = removalRequests.first(where: {
                          $0.request.secretId == meta.secretId && $0.request.recipientKey == contact.verifyKey
                              && $0.request.state == .approved && verifyRespond($0.request)
                      })
                else { continue }
                // Local record first, relay row second. The row is the evidence; dropping it before
                // acting on it would leave a holder that can never be reconciled if this device dies
                // in between, which is the one failure this whole flow exists to avoid.
                try? shareMetadataRepository.delete(shareId: meta.id)
                try? await approvedRemoval.relay.deleteShareRequest(requestId: approvedRemoval.request.id)
            }
        }

        // Only a destruction ends the secret itself. A holder removed from an active secret leaves
        // it one holder short, which is what its health already shows.
        let remaining = Set(((try? shareMetadataRepository.getAll()) ?? []).map(\.secretId))
        for secret in (try? secretRepository.getAll()) ?? [] where secret.state == .destroying && !remaining.contains(secret.id) {
            try? secretRepository.delete(secretId: secret.id)
        }
    }

    public func listSentRequests() async throws -> RelayFanOut<ShareRequest> {
        await rowsAcrossRelays(role: .sender).mapItems { rows in
            rows.map(\.request).filter { $0.transactionType != .deposit }
        }
    }

    // A holder is worth prioritizing for a fresh retrieval ask when the custody-freshness rule
    // that decides "still counts toward n_live" already trusts them: an unexpired
    // proof-of-custody and no standing opt-out. Recomputed here (not shared with the UI layer's
    // own FreshnessBucket, which serves display, not targeting) — a small, deliberate duplication
    // of a threshold check rather than restructuring the already-shipped freshness UI.
    private func isConfirmed(_ meta: ShareMetadata) -> Bool {
        guard let contact = contactRepository.getById(meta.contactId), contact.heartbeatOptedOutAt == nil,
            let lastConfirmedAt = meta.lastConfirmedAt else { return false }
        return Date().timeIntervalSince(lastConfirmedAt) <= CustodyHeartbeatTuning.lossThreshold
    }

    public func requestAll(secretId: UUID) async throws {
        guard let secret = (try? secretRepository.getAll())?.first(where: { $0.id == secretId }) else { return }
        let deposited = (try? shareMetadataRepository.getAll()) ?? []
        let forSecret = deposited.filter { $0.secretId == secretId }
        let existingRows = await rowsAcrossRelays(role: .sender, transactionType: .retrieval).items
        let existing = existingRows.map(\.request)
        // Fan out to the health-informed fresh set first; widen to everyone only when
        // there aren't enough confirmed holders to reach k. A retrieval request exists solely to
        // feed an eventual reconstruct(), so this targeting applies here rather than as a
        // separate method.
        let confirmed = forSecret.filter(isConfirmed)
        let targets = confirmed.count >= secret.k ? confirmed : forSecret
        for meta in targets {
            guard let contact = contactRepository.getById(meta.contactId) else { continue }
            // Matched on secretId plus the holder's key. Not secretId alone — every holder of a
            // secret shares it, so one standing row would silence the whole fan-out. A holder who
            // rotated keys since the row was opened no longer matches, which is right: that row is
            // unreachable under the new key anyway.
            let hasActive = existing.contains {
                $0.secretId == meta.secretId && $0.recipientKey == contact.verifyKey
                    && ($0.state == .pending || $0.state == .approved)
            }
            if !hasActive, let sealedLabel = try? encryption.sealLabel(secret.label, recipientEncKey: contact.encKey) {
                let canon = PayloadCanonical.forOpen(secretId: meta.secretId, transactionType: .retrieval, recipientKey: contact.verifyKey, sealedLabel: sealedLabel, secretCreatedAt: secret.secretCreatedAt, ciphertext: nil)
                if let senderSignature = try? identity.sign(canon),
                   (try? await relay(for: contact).openShareRequest(
                       secretId: meta.secretId,
                       recipientKey: contact.verifyKey,
                       sealedLabel: sealedLabel,
                       secretCreatedAt: secret.secretCreatedAt,
                       transactionType: .retrieval,
                       ciphertext: nil,
                       k: nil,
                       n: nil,
                       mimeType: nil,
                       senderSignature: senderSignature
                   )) != nil {
                    let denied = existingRows.filter {
                        $0.request.secretId == meta.secretId && $0.request.recipientKey == contact.verifyKey
                            && $0.request.state == .denied
                    }
                    for row in denied {
                        try? await row.relay.deleteShareRequest(requestId: row.request.id)
                    }
                }
            }
        }
    }

    /// A denied answer has been acted on once the ask is made again: the new request replaces it,
    /// so it goes, after the new one is open. Looked for on the relay the new one went to, which is
    /// where earlier asks to this holder went.
    private func dropDeniedAnswers(on relay: any ShareRelay, secretId: UUID, holder: Contact, type: ShareTransactionType) async {
        let denied = (try? await relay.listShareRequests(role: .sender, transactionType: type, state: .denied)) ?? []
        for row in denied where row.secretId == secretId && row.recipientKey == holder.verifyKey {
            try? await relay.deleteShareRequest(requestId: row.id)
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
        let sealedLabel = try encryption.sealLabel(secret.label, recipientEncKey: contact.encKey)
        let canon = PayloadCanonical.forOpen(secretId: meta.secretId, transactionType: type, recipientKey: contact.verifyKey, sealedLabel: sealedLabel, secretCreatedAt: secret.secretCreatedAt, ciphertext: nil)
        let senderSignature = try identity.sign(canon)
        let target = relay(for: contact)
        let opened = try await target.openShareRequest(
            secretId: meta.secretId,
            recipientKey: contact.verifyKey,
            sealedLabel: sealedLabel,
            secretCreatedAt: secret.secretCreatedAt,
            transactionType: type,
            ciphertext: nil,
            k: nil,
            n: nil,
            mimeType: nil,
            senderSignature: senderSignature
        )
        await dropDeniedAnswers(on: target, secretId: meta.secretId, holder: contact, type: type)
        return opened
    }

    /// Pure read: collects and decrypts `k` approved retrieval shares, but never tears
    /// down local `ShareMetadata` or relay rows. Use `destroySecret` for teardown — reconstruct is
    /// now a *step* toward a possible re-split, not an implicit "I'm done with this" signal.
    public func reconstruct(secretId: UUID) async throws -> ReconstructionResult {
        guard let secret = (try? secretRepository.getAll())?.first(where: { $0.id == secretId }) else {
            throw ShareServiceError.secretNotFound
        }
        let allRequests = await rowsAcrossRelays(role: .sender, transactionType: .retrieval).items
        // An unverified recipientSignature is treated as "not yet approved" rather than a hard
        // error — a forged approval simply doesn't count toward the threshold.
        let approved = allRequests.filter { pair in
            pair.request.secretId == secretId && pair.request.state == .approved && pair.request.ciphertext != nil && verifyRespond(pair.request)
        }
        guard approved.count >= secret.k else {
            throw ShareServiceError.notEnoughApprovedShares(have: approved.count, need: secret.k)
        }
        // Each decrypted share is kept paired with its originating contact so an
        // excluded index (from combineWithIntegrity) reports back as a suspect contact, not a
        // meaningless array position.
        var decryptedShares: [[UInt8]] = []
        var contactIds: [UUID] = []
        for pair in approved {
            let ct = pair.request.ciphertext!
            guard let contact = contactRepository.getByVerifyKey(pair.request.recipientKey) else {
                throw ShareServiceError.contactNotFound
            }
            let plaintext = try encryption.decrypt(ct)
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
        return ReconstructionResult(secret: Data(result.secret), integrity: integrity, mimeType: secret.mimeType)
    }

    /// Deletes every retrieval row for `secretId` through the relay it was found on — approved and
    /// still pending alike, so that afterwards there is no retrieval flow for this secret at all:
    /// `requestAll` asks every holder again (it skips only holders with a live row, and none are
    /// left) and `reconstruct` refuses until they answer.
    ///
    /// Clearing the approved rows alone would leave asks that nobody has answered yet still
    /// standing, and copies would go on arriving after the sender said they were finished.
    ///
    /// Each deletion is soft-failed on its own: one unreachable relay must not strand the rows
    /// held on the others.
    public func clearCollectedShares(secretId: UUID) async throws {
        let rows = await rowsAcrossRelays(role: .sender, transactionType: .retrieval).items
        for (relay, request) in rows where request.secretId == secretId {
            try? await relay.deleteShareRequest(requestId: request.id)
        }
    }

    /// Fans out a sender-initiated `removal` to every known holder of `secretId` and flips the
    /// `Secret` to `.destroying` immediately, before any holder has responded.
    public func destroySecret(secretId: UUID) async throws {
        guard let secret = (try? secretRepository.getAll())?.first(where: { $0.id == secretId }) else {
            throw ShareServiceError.secretNotFound
        }
        try secretRepository.save(Secret(id: secret.id, label: secret.label, mimeType: secret.mimeType, k: secret.k, n: secret.n, secretCreatedAt: secret.secretCreatedAt, state: .destroying))
        let shares = ((try? shareMetadataRepository.getAll()) ?? []).filter { $0.secretId == secretId }
        for share in shares {
            _ = try? await openRequest(shareId: share.id, type: .removal)
        }
    }

    /// Local-only teardown for a `.destroying` secret whose holders won't all respond (e.g. a
    /// permanently dark holder) — removes the `Secret` and its remaining `ShareMetadata` rows
    /// without waiting for relay confirmation.
    public func forceForgetSecret(secretId: UUID) throws {
        let shares = ((try? shareMetadataRepository.getAll()) ?? []).filter { $0.secretId == secretId }
        for share in shares {
            try? shareMetadataRepository.delete(shareId: share.id)
        }
        try secretRepository.delete(secretId: secretId)
    }

    // MARK: - Recipient flows

    @discardableResult
    public func syncInbox() async throws -> SyncReport {
        var failures = RelayFailures()
        for relay in allRelays() {
            let pending = await fromRelay(relay, &failures) {
                try await relay.listShareRequests(role: .recipient, transactionType: .deposit, state: .pending)
            }
            // Unknown sender or unverified senderSignature: skip silently, do not auto-approve.
            for req in pending where verifyOpen(req) {
                guard let senderContact = contactRepository.getByVerifyKey(req.senderKey) else { continue }
                noteRelinked(senderContact)
                // A deposit without valid k/n/mimeType can't happen against a conforming relay
                // (all three required by ShareRequestsService) — skip defensively rather than store
                // a share we can't later report thresholds for during recovery.
                guard let k = req.k, let n = req.n, let mimeType = req.mimeType else { continue }
                // Order is load-bearing: approving is what clears the relay's only copy of the
                // ciphertext, so it is the last step of pickup and never the first. Decrypting and
                // storing first means a failure leaves the row pending with the relay's copy
                // intact, and the next poll simply retries. The ciphertext is already in hand and
                // already authenticated — verifyOpen above covers it — so the approval response's
                // echoed copy adds nothing.
                if shareRepository.getPlaintextShare(secretId: req.secretId) == nil {
                    guard let ct = req.ciphertext,
                          let plaintext = try? encryption.decrypt(ct),
                          let label = try? encryption.openLabel(req.sealedLabel)
                    else { continue }
                    shareRepository.save(HeldShare(
                        id: req.id,
                        secretId: req.secretId,
                        label: label,
                        contactId: senderContact.id,
                        senderPseudonym: senderContact.pseudonym,
                        createdAt: req.secretCreatedAt,
                        pickedUpAt: Date(),
                        plaintextShare: plaintext,
                        k: k,
                        n: n,
                        mimeType: mimeType
                    ))
                }
                // Sent even when an earlier poll already stored the share but failed to acknowledge
                // it: without the approval the sender never observes the pickup, and the deposit
                // sits on the relay until it expires.
                let canon = PayloadCanonical.forRespond(requestId: req.id, approved: true, ciphertext: nil)
                guard let recipientSignature = try? identity.sign(canon) else { continue }
                _ = try? await relay.respondToShareRequest(requestId: req.id, approved: true, ciphertext: nil, recipientSignature: recipientSignature)
            }
        }
        await processRecoveryMetadata(&failures)
        await processRotations(&failures)
        await emitHeartbeats(failures)
        return failures.report
    }

    /// Holder side — opportunistically piggybacks this same inbox poll: for each
    /// distinct sender this device currently holds at least one share from, pushes one coalesced
    /// heartbeat (or opt-out notice) once the per-sender emission interval has elapsed. Each push
    /// is independently best-effort so one unreachable BYOR relay doesn't block heartbeating
    /// other senders. `lastHeartbeatSentAt` only advances on a *successful* push, so a transient
    /// failure retries on the very next poll rather than waiting out the full interval again.
    /// A sender whose relay has gone silent in this pass is not pushed to at all, for the reason
    /// `fromRelay` gives, and is retried on the next poll the same way.
    private func emitHeartbeats(_ failures: RelayFailures) async {
        let held = shareRepository.getAll()
        let senderIds = Set(held.map(\.contactId))
        let now = Date()
        for contactId in senderIds {
            guard let contact = contactRepository.getById(contactId),
                  !failures.unreachable.contains(relay(for: contact).baseUrl) else { continue }
            let dueSince = contact.lastHeartbeatSentAt.map { now.timeIntervalSince($0) } ?? .infinity
            guard dueSince >= CustodyHeartbeatTuning.emissionInterval else { continue }
            let secretIds = contact.heartbeatEmissionOptedOut ? [] : held.filter { $0.contactId == contactId }.map(\.secretId)
            // Signed as whole milliseconds and sent as `wireInstant`, which carries exactly those.
            let canon = PayloadCanonical.forHeartbeat(ownerKey: contact.verifyKey, secretIds: secretIds, optedOut: contact.heartbeatEmissionOptedOut, emittedAt: now)
            guard let signature = try? identity.sign(canon) else { continue }
            do {
                try await relay(for: contact).pushHeartbeat(ownerKey: contact.verifyKey, secretIds: secretIds, optedOut: contact.heartbeatEmissionOptedOut, emittedAt: now, signature: signature)
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

    // Anything arriving from a contact proves they hold this device's current key, because the
    // relay only ever returns rows addressed to the caller — so every inbound path notes it, and a
    // contact who has relinked drops off the awaiting-relink list without anyone tapping anything.
    // Rows this device created itself, which syncDistributed reads back, prove nothing about the
    // contact and are deliberately not counted.
    private func noteRelinked(_ contact: Contact) {
        contactManagement.markRelinked(contact.id)
    }

    /// Owner side — auto-verifies each holder's unread heartbeat (or opt-out notice)
    /// against a known contact's trusted key, updates local freshness/opt-out state, then deletes
    /// the heartbeat: what it said is kept here, and the holder re-emits every interval. One from an
    /// unknown key, or with a signature that fails, changes nothing and is deleted all the same.
    /// That is where heartbeats part from `processRotations()`, which leaves such a notice alone: a
    /// rotation is sent once, while a heartbeat has a newer one behind it. Left on the relay, one
    /// from a contact this device has since deleted would be refreshed by every push its holder
    /// still makes, and so never expire.
    ///
    /// Dated by the holder's signed `emittedAt`, and never backwards: a heartbeat older than what
    /// this device already knows refreshes nothing, so a relay re-serving an old one gains
    /// nothing. Never later than this device's own clock either, so a holder whose clock runs ahead
    /// cannot date proof of custody into the owner's future. The opt-out follows the same rule,
    /// with one gap left open on purpose: a replayed old opt-out still marks a holder unmonitored,
    /// which takes them out of n_live — it can raise an alarm, never silence one.
    private func processHeartbeats(_ failures: inout RelayFailures) async {
        // Nothing here can be verified without our own key, so a device whose key storage is locked
        // does nothing and picks this up on a later pass rather than failing every notice.
        guard let myKey = identity.verifyKey else { return }
        let existingMetadata = (try? shareMetadataRepository.getAll()) ?? []
        let now = Date()
        for relay in allRelays() {
            let notices = await fromRelay(relay, &failures) { try await relay.listHeartbeats() }
            for notice in notices {
                if let contact = contactRepository.getByVerifyKey(notice.holderKey) {
                    noteRelinked(contact)
                    let canon = PayloadCanonical.forHeartbeat(ownerKey: myKey, secretIds: notice.secretIds, optedOut: notice.optedOut, emittedAt: notice.emittedAt)
                    if identity.verify(canon, signature: notice.signature, publicKey: notice.holderKey) {
                        applyHeartbeat(notice, from: contact, existingMetadata: existingMetadata, now: now)
                    }
                }
                try? await relay.deleteHeartbeat(id: notice.id)
            }
        }
    }

    private func applyHeartbeat(_ notice: CustodyHeartbeat, from contact: Contact, existingMetadata: [ShareMetadata], now: Date) {
        let emittedAt = min(notice.emittedAt, now)
        if notice.optedOut {
            if contact.heartbeatOptedOutAt.map({ $0 < emittedAt }) ?? true {
                contactRepository.save(Contact(
                    id: contact.id, pseudonym: contact.pseudonym, verifyKey: contact.verifyKey, encKey: contact.encKey,
                    verificationLevel: contact.verificationLevel, verifiedAt: contact.verifiedAt, addedAt: contact.addedAt,
                    relayBaseUrl: contact.relayBaseUrl, revokedVerifyKeys: contact.revokedVerifyKeys, keyChangedAt: contact.keyChangedAt,
                    heartbeatOptedOutAt: emittedAt, lastHeartbeatSentAt: contact.lastHeartbeatSentAt, heartbeatEmissionOptedOut: contact.heartbeatEmissionOptedOut,
                    cipherSuite: contact.cipherSuite, nickname: contact.nickname
                ))
            }
            return
        }
        if let optedOutAt = contact.heartbeatOptedOutAt, optedOutAt < emittedAt {
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
            if meta.lastConfirmedAt.map({ $0 < emittedAt }) ?? true {
                try? shareMetadataRepository.save(ShareMetadata(id: meta.id, secretId: meta.secretId, contactId: meta.contactId, lastConfirmedAt: emittedAt))
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

    /// Receiving side — auto-verifies a signed rotation notice against the trusted old
    /// key already on file for a known contact, downgrades the verification level to at most
    /// `.low` (a signed rotation proves continuity of key control, not a fresh personhood check,
    /// so it can never carry a higher level forward), and updates the contact record in place,
    /// preserving `contactId`. Unknown senders and forged/mismatched signatures are silently
    /// skipped — a stranger's notice must never mutate a real contact.
    private func processRotations(_ failures: inout RelayFailures) async {
        for relay in allRelays() {
            let notices = await fromRelay(relay, &failures) { try await relay.listRotations() }
            for notice in notices {
                guard let contact = contactRepository.getByVerifyKey(notice.oldVerifyKey) else { continue }
                noteRelinked(contact)
                let canon = PayloadCanonical.forRotation(recipientKey: notice.recipientKey, newVerifyKey: notice.newVerifyKey, newEncKey: notice.newEncKey, newCipherSuite: notice.newCipherSuite)
                guard identity.verify(canon, signature: notice.signature, publicKey: notice.oldVerifyKey) else { continue }
                // A stolen key can't revoke itself, but a locally-flagged one blocks
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
                // A cipher-suite-only change is likewise "continuity of key control, not
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

    /// Sending side (client primitive only — see `ShareManagement.pushRotation`). Signs
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

    /// The identity-regeneration trigger. Order matters: the drain and the rotation pushes must
    /// both happen *before* `activateKeyPair`, since `pushRotation` (and the drain's own calls)
    /// sign with whatever identity is currently persisted — that's what proves continuity from the
    /// old key to each contact. If the app dies partway through, the old identity is still active
    /// (nothing was persisted yet), so a retry simply regenerates and re-pushes from scratch; any
    /// contact who received an orphaned first attempt auto-corrects on the next successful push,
    /// per the existing `K_old`-signed auto-accept rule.
    ///
    /// The drain succeeded only if both passes ran and every relay answered them: it is about to
    /// retire the identity those rows are addressed to, so a relay that went unheard is exactly
    /// what it must report. A relay that refused went unheard just as much.
    public func regenerateIdentity() async throws -> RegenerateIdentityResult {
        let inbox = try? await syncInbox()
        let distributed = try? await syncDistributed()
        let drainSucceeded = inbox?.everyRelayAnswered == true && distributed?.everyRelayAnswered == true
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
        return RegenerateIdentityResult(notifiedContacts: notified, totalContacts: contacts.count, drainSucceeded: drainSucceeded)
    }

    /// Identity recovery — sender/owner side. Consumes pending `recoveryMetadata` pushes
    /// addressed to this device, rebuilding `Secret`/`ShareMetadata` records from what each holder
    /// reports. A push is trusted only once its `senderSignature` verifies against a *known*
    /// contact — the holder must already have been re-added out-of-band before
    /// their push is honored. Consumed rows are deleted from the relay once processed.
    private func processRecoveryMetadata(_ failures: inout RelayFailures) async {
        for relay in allRelays() {
            let pushes = await fromRelay(relay, &failures) {
                try await relay.listShareRequests(role: .recipient, transactionType: .inventory, state: .approved)
            }
            for req in pushes where verifyOpen(req) {
                guard let holderContact = contactRepository.getByVerifyKey(req.senderKey) else { continue }
                noteRelinked(holderContact)
                guard let k = req.k, let n = req.n, let mimeType = req.mimeType else { continue }
                let existingSecrets = (try? secretRepository.getAll()) ?? []
                if !existingSecrets.contains(where: { $0.id == req.secretId }) {
                    // A label that will not open leaves the row for the next poll, rather than rebuilding a
                    // secret nobody could recognise.
                    guard let label = try? encryption.openLabel(req.sealedLabel) else { continue }
                    try? secretRepository.save(Secret(id: req.secretId, label: label, mimeType: mimeType, k: k, n: n, secretCreatedAt: req.secretCreatedAt, state: .active))
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
            guard let sealedLabel = try? encryption.sealLabel(share.label, recipientEncKey: contact.encKey) else { continue }
            let canon = PayloadCanonical.forOpen(secretId: share.secretId, transactionType: .inventory, recipientKey: contact.verifyKey, sealedLabel: sealedLabel, secretCreatedAt: share.createdAt, ciphertext: nil, k: share.k, n: share.n, mimeType: share.mimeType)
            guard let senderSignature = try? identity.sign(canon) else { continue }
            _ = try? await relay(for: contact).openShareRequest(
                secretId: share.secretId,
                recipientKey: contact.verifyKey,
                sealedLabel: sealedLabel,
                secretCreatedAt: share.createdAt,
                transactionType: .inventory,
                ciphertext: nil,
                k: share.k,
                n: share.n,
                mimeType: share.mimeType,
                senderSignature: senderSignature
            )
        }
    }

    public func listHeld() throws -> [HeldShare] {
        shareRepository.getAll()
    }

    public func listPendingRequests() async throws -> RelayFanOut<ShareRequest> {
        // A forged removal/retrieval request has no AEAD backstop — must never reach the UI.
        await rowsAcrossRelays(role: .recipient, state: .pending).mapItems { rows in
            rows.map(\.request).filter { $0.transactionType != .deposit && verifyOpen($0) }
        }
    }

    public func label(of request: ShareRequest) -> String? {
        // A box proves nothing about who sealed it, so a label is opened only for a request whose
        // signature verifies.
        if verifyOpen(request), let label = try? encryption.openLabel(request.sealedLabel) {
            return label
        }
        // A label sealed to a key two rotations back no longer opens. The share held for that secret
        // still names it.
        return shareRepository.getAll().first { $0.secretId == request.secretId }?.label
    }

    public func respond(requestId: UUID, approved: Bool) async throws {
        let (relay, request) = try await findShareRequest(requestId)
        guard verifyOpen(request) else {
            throw ShareServiceError.signatureVerificationFailed("senderSignature does not verify for request \(requestId)")
        }
        let ciphertext: Data?
        if approved && request.transactionType == .retrieval {
            // Matched on secretId: the request names the secret, and a holder keeps one share per
            // secret per sender.
            guard let plaintext = shareRepository.getPlaintextShare(secretId: request.secretId) else {
                throw ShareServiceError.shareNotFound
            }
            // Re-encrypt to the requester's *current* X25519 key — looked up live, not pinned at
            // deposit time. This is what lets reconstruction survive a sender key rotation/
            // recovery — the core reason the holder decrypts at pickup.
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

    /// Unilateral, no approval needed — but not purely silent: best-effort tells the sender with
    /// a signed withdrawal before the local record is dropped. The push is fire-and-forget; local
    /// deletion always proceeds regardless of its outcome.
    public func deleteHeldShare(shareId: UUID) async throws {
        if let share = shareRepository.getAll().first(where: { $0.id == shareId }),
           let senderContact = contactRepository.getById(share.contactId) {
            try? await pushWithdrawal(share, to: senderContact)
        }
        shareRepository.delete(shareId: shareId)
    }

    /// Same best-effort withdrawal as `deleteHeldShare`, one per share from `contactId`.
    public func deleteAllHeldFromSender(contactId: UUID) async throws {
        let shares = shareRepository.getAll().filter { $0.contactId == contactId }
        if let senderContact = contactRepository.getById(contactId) {
            for share in shares {
                try? await pushWithdrawal(share, to: senderContact)
            }
        }
        for share in shares {
            shareRepository.delete(shareId: share.id)
        }
    }

    /// The holder's signed "I no longer hold this", addressed to the share's owner — the label
    /// sealed to her like any other row, the share itself never included. Signed, so a relay
    /// cannot invent one, and addressed to her current key, so it reaches her across any rotation
    /// either side has made since the deposit.
    private func pushWithdrawal(_ share: HeldShare, to owner: Contact) async throws {
        let sealedLabel = try encryption.sealLabel(share.label, recipientEncKey: owner.encKey)
        let canon = PayloadCanonical.forOpen(secretId: share.secretId, transactionType: .withdrawal, recipientKey: owner.verifyKey, sealedLabel: sealedLabel, secretCreatedAt: share.createdAt, ciphertext: nil)
        let senderSignature = try identity.sign(canon)
        _ = try await relay(for: owner).openShareRequest(
            secretId: share.secretId,
            recipientKey: owner.verifyKey,
            sealedLabel: sealedLabel,
            secretCreatedAt: share.createdAt,
            transactionType: .withdrawal,
            ciphertext: nil,
            k: nil,
            n: nil,
            mimeType: nil,
            senderSignature: senderSignature
        )
    }
}

import hexagon
import Foundation

/// The three-bucket custody-freshness model — see `CustodyHeartbeatTuning` for the underlying
/// windows and the reasoning behind them.
enum FreshnessBucket {
    /// Proof-of-custody (heartbeat, pickup, or retrieve approval) observed within
    /// `CustodyHeartbeatTuning.lossThreshold`. Counts toward `n_live`.
    case confirmed
    /// The holder sent a signed opt-out notice — never a loss alarm, shown as a standing
    /// advisory instead. Does not count toward `n_live`.
    case unmonitored
    /// Expected proof-of-custody hasn't arrived within the loss threshold (or never has).
    /// Drops out of `n_live` — reversible the moment a fresh heartbeat/approval is observed.
    case silentOverdue
}

struct HolderStatus: Identifiable {
    let shareId: UUID           // ShareMetadata.id (the Deposit request id)
    let contactId: UUID
    let retrievalRequest: ShareRequest?
    let lastConfirmedAt: Date?
    let heartbeatOptedOutAt: Date?
    var id: UUID { shareId }

    var freshnessBucket: FreshnessBucket {
        if heartbeatOptedOutAt != nil { return .unmonitored }
        if let lastConfirmedAt, Date().timeIntervalSince(lastConfirmedAt) <= CustodyHeartbeatTuning.lossThreshold {
            return .confirmed
        }
        return .silentOverdue
    }

    /// The early nudge — surfaced before a holder actually drops out of `n_live`, while
    /// still comfortably `.confirmed`.
    var isGettingStale: Bool {
        guard freshnessBucket == .confirmed, let lastConfirmedAt else { return false }
        return Date().timeIntervalSince(lastConfirmedAt) > CustodyHeartbeatTuning.staleWarningThreshold
    }
}

enum SecretHealth {
    case healthy, caution, critical, lost
    /// `state == .destroying` suppresses the health alarm entirely — a dropping holder count is
    /// the goal, not a problem.
    case destroying
}

struct SecretGroup: Identifiable {
    let secret: Secret
    let holders: [HolderStatus]
    var id: UUID { secret.id }

    /// `n_live` is the freshness-gated `.confirmed` count, not a raw
    /// `ShareMetadata`-row count: an `.unmonitored` holder never alarms, and a `.silentOverdue`
    /// one drops out (reversibly) instead of being counted as still-live.
    var health: SecretHealth {
        guard secret.state == .active else { return .destroying }
        let nLive = holders.filter { $0.freshnessBucket == .confirmed }.count
        let k = secret.k
        if nLive < k { return .lost }
        if nLive == k { return .critical }
        if nLive == k + 1 { return .caution }
        return .healthy
    }

    var unmonitoredCount: Int { holders.filter { $0.freshnessBucket == .unmonitored }.count }

    /// Mirrors what `requestAll` actually does — it skips a holder whose retrieval row is
    /// `.pending` or `.approved` — so the press is worth offering while any holder still lacks one,
    /// and is a no-op only once nobody is left to ask.
    ///
    /// Deliberately still enabled once k copies are in: a surplus beyond the threshold is what lets
    /// reconstruct cross-check the shares it has, so asking the stragglers is how a "no integrity
    /// margin" outcome becomes a confirmed one.
    var canRequestRetrieval: Bool {
        secret.state == .active && holders.contains { holder in
            let state = holder.retrievalRequest?.state
            return state != .pending && state != .approved
        }
    }

    /// Why **Retrieve shares** cannot be pressed, or nil when it can be. A control that cannot work
    /// says so in words rather than disappearing.
    var retrievalUnavailableReason: String? {
        if secret.state != .active {
            return String(localized: "This secret is being destroyed.")
        }
        if !canRequestRetrieval {
            return String(localized: "Every holder has been asked already.")
        }
        return nil
    }

    var approvedRetrievals: Int {
        holders.filter { $0.retrievalRequest?.state == .approved }.count
    }

    var canReconstruct: Bool { approvedRetrievals >= secret.k }

    /// How many more holders have to hand a piece back before the secret can be put together.
    var reconstructShortfall: Int { max(0, secret.k - approvedRetrievals) }

    /// Collected copies are what there is to clear. An ask still waiting for an answer is cleared
    /// along with them, but on its own means nothing has been collected yet.
    var canClearCollected: Bool { approvedRetrievals > 0 }
}

@Observable
final class HomeViewModel {

    var groupedSecrets: [SecretGroup] = []
    var heldShares: [HeldShare] = []
    var isLoading = false
    var syncWarning = false
    /// How many contacts still hold a key this device no longer signs with. A standing advisory
    /// rather than an alarm: it is expected work after a phone switch, and it clears itself as each
    /// contact gets back in touch.
    var awaitingRelinkCount = 0
    var error: String?

    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement

    init(shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
    }

    func load() async {
        isLoading = true
        error = nil
        syncWarning = false

        // Phase 1: local data only — renders immediately even when offline
        do {
            let secrets = try shareManagement.listSecrets()
            let distributed = try shareManagement.listDistributed()
            let contacts = (try? contactManagement.listContacts()) ?? []
            groupedSecrets = Self.buildGroups(secrets: secrets, distributed: distributed, allRequests: [], contacts: contacts)
            heldShares = try shareManagement.listHeld()
            awaitingRelinkCount = contactManagement.contactsAwaitingRelink().count
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            return
        }
        isLoading = false

        // Phase 2: relay sync — soft failure, never wipes Phase 1 results
        do {
            try await shareManagement.syncInbox()
            try await shareManagement.syncDistributed()
            let allRequests = try await shareManagement.listSentRequests()
            let secrets = try shareManagement.listSecrets()
            let distributed = try shareManagement.listDistributed()
            let contacts = (try? contactManagement.listContacts()) ?? []
            groupedSecrets = Self.buildGroups(secrets: secrets, distributed: distributed, allRequests: allRequests, contacts: contacts)
            heldShares = try shareManagement.listHeld()
            // The sync may itself be the evidence that clears someone.
            awaitingRelinkCount = contactManagement.contactsAwaitingRelink().count
        } catch {
            syncWarning = true
        }
    }

    /// One group per secret, holders folded in — shared with a single secret's own screen, so both
    /// read the same rules off the same rows.
    static func buildGroups(secrets: [Secret], distributed: [ShareMetadata], allRequests: [ShareRequest], contacts: [Contact]) -> [SecretGroup] {
        let bySecret = Dictionary(grouping: distributed, by: { $0.secretId })
        let contactsById = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        return secrets.map { secret in
            let shares = bySecret[secret.id] ?? []
            let holders = shares.map { share -> HolderStatus in
                // flatMap over the *contact*, not over its verifyKey: `Data` is a Sequence, so
                // `?.verifyKey.flatMap` binds Sequence.flatMap and hands back bytes rather than
                // the key.
                let latestRetrieval = contactsById[share.contactId].flatMap { holder in
                    allRequests
                        .filter { $0.secretId == share.secretId && $0.recipientKey == holder.verifyKey && $0.transactionType == .retrieval }
                        .max { $0.requestedAt < $1.requestedAt }
                }
                return HolderStatus(
                    shareId: share.id, contactId: share.contactId, retrievalRequest: latestRetrieval,
                    lastConfirmedAt: share.lastConfirmedAt, heartbeatOptedOutAt: contactsById[share.contactId]?.heartbeatOptedOutAt
                )
            }
            return SecretGroup(secret: secret, holders: holders)
        }
        .sorted { $0.secret.secretCreatedAt > $1.secret.secretCreatedAt }
    }
}

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
    /// `state == .discarding` suppresses the health alarm entirely — a dropping holder count is
    /// the goal, not a problem.
    case discarding
}

struct SecretGroup: Identifiable {
    let secret: Secret
    let holders: [HolderStatus]
    var id: UUID { secret.id }

    /// `n_live` is the freshness-gated `.confirmed` count, not a raw
    /// `ShareMetadata`-row count: an `.unmonitored` holder never alarms, and a `.silentOverdue`
    /// one drops out (reversibly) instead of being counted as still-live.
    var health: SecretHealth {
        guard secret.state == .active else { return .discarding }
        let nLive = holders.filter { $0.freshnessBucket == .confirmed }.count
        let k = secret.k
        if nLive < k { return .lost }
        if nLive == k { return .critical }
        if nLive == k + 1 { return .caution }
        return .healthy
    }

    var unmonitoredCount: Int { holders.filter { $0.freshnessBucket == .unmonitored }.count }
}

@Observable
final class HomeViewModel {

    var groupedSecrets: [SecretGroup] = []
    var heldShares: [HeldShare] = []
    var isLoading = false
    var syncWarning = false
    var error: String?
    var requestingAllIds: Set<UUID> = []

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
        } catch {
            syncWarning = true
        }
    }

    func requestAll(secretId: UUID) async {
        requestingAllIds.insert(secretId)
        try? await shareManagement.requestAll(secretId: secretId)
        requestingAllIds.remove(secretId)
        await load()
    }

    func discardSecret(_ secretId: UUID) async {
        try? await shareManagement.discardSecret(secretId: secretId)
        await load()
    }

    func forceForgetSecret(_ secretId: UUID) async {
        try? shareManagement.forceForgetSecret(secretId: secretId)
        await load()
    }

    private static func buildGroups(secrets: [Secret], distributed: [ShareMetadata], allRequests: [ShareRequest], contacts: [Contact]) -> [SecretGroup] {
        let bySecret = Dictionary(grouping: distributed, by: { $0.secretId })
        let contactsById = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        return secrets.map { secret in
            let shares = bySecret[secret.id] ?? []
            let holders = shares.map { share -> HolderStatus in
                let latestRetrieval = contactsById[share.contactId]?.verifyKey.flatMap { holderKey in
                    allRequests
                        .filter { $0.secretId == share.secretId && $0.recipientKey == holderKey && $0.transactionType == .retrieval }
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

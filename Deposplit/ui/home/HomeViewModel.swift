import hexagon
import Foundation

struct HolderStatus: Identifiable {
    let shareId: UUID           // ShareMetadata.id (the PickUp request id)
    let contactId: UUID
    let retrieveRequest: ShareRequest?
    var id: UUID { shareId }
}

enum SecretHealth {
    case healthy, caution, critical, lost
    /// `state == .discarding` suppresses the health alarm entirely — a dropping holder count is
    /// the goal, not a problem. See deposplit.com/CLAUDE.md "What is next" item 11.
    case discarding
}

struct SecretGroup: Identifiable {
    let secret: Secret
    let holders: [HolderStatus]
    var id: UUID { secret.id }

    /// `n_live` here is a pre-item-9/12 proxy: the count of holders this device currently still
    /// tracks a `ShareMetadata` row for. Item 12 later refines this into a freshness-gated count;
    /// item 11 only introduces the count-vs-`k` comparison itself.
    var health: SecretHealth {
        guard secret.state == .active else { return .discarding }
        let nLive = holders.count
        let k = secret.k
        if nLive < k { return .lost }
        if nLive == k { return .critical }
        if nLive == k + 1 { return .caution }
        return .healthy
    }
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

    init(shareManagement: any ShareManagement) {
        self.shareManagement = shareManagement
    }

    func load() async {
        isLoading = true
        error = nil
        syncWarning = false

        // Phase 1: local data only — renders immediately even when offline
        do {
            let secrets = try shareManagement.listSecrets()
            let distributed = try shareManagement.listDistributed()
            groupedSecrets = Self.buildGroups(secrets: secrets, distributed: distributed, allRequests: [])
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
            groupedSecrets = Self.buildGroups(secrets: secrets, distributed: distributed, allRequests: allRequests)
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

    private static func buildGroups(secrets: [Secret], distributed: [ShareMetadata], allRequests: [ShareRequest]) -> [SecretGroup] {
        let bySecret = Dictionary(grouping: distributed, by: { $0.secretId })
        return secrets.map { secret in
            let shares = bySecret[secret.id] ?? []
            let holders = shares.map { share -> HolderStatus in
                let latestRetrieve = allRequests
                    .filter { $0.shareId == share.id && $0.requestType == .retrieve }
                    .max { $0.requestedAt < $1.requestedAt }
                return HolderStatus(shareId: share.id, contactId: share.contactId, retrieveRequest: latestRetrieve)
            }
            return SecretGroup(secret: secret, holders: holders)
        }
        .sorted { $0.secret.secretCreatedAt > $1.secret.secretCreatedAt }
    }
}

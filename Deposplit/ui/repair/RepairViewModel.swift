import hexagon
import Foundation

/// The "reconstruct-and-re-split" repair flow — composes three already-existing primitives
/// (`reconstruct`, `deposit`, `discardSecret`) that were previously only reachable from three
/// disconnected screens. What gives the flow a reason to be surfaced is the freshness-gated
/// health signal: a secret whose live holder count has fallen needs repairing, not discarding.
@Observable
final class RepairViewModel {

    enum Phase {
        case gathering
        case reconstructing
        case redeposit
        case confirmDiscard
        case done
    }

    struct HolderRetrievalStatus: Identifiable {
        let contactId: UUID
        let pseudonym: String
        let requestState: ShareRequestState?
        // The contact's actual pseudonym, shown as a secondary line, but only when
        // `pseudonym` above is actually a nickname; nil otherwise.
        var subtitle: String?
        var id: UUID { contactId }
    }

    let secret: Secret
    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement

    var phase: Phase = .gathering
    var isLoading = false
    var isActing = false
    var error: String?
    var holderStatuses: [HolderRetrievalStatus] = []
    var approvedCount = 0
    var depositedHolderCount = 0
    /// The integrity cross-check result, set once `reconstruct()` succeeds.
    var reconstructionIntegrity: ReconstructionIntegrity?

    /// The prefilled re-deposit form for the `.redeposit` phase — constructed (with the freshly
    /// reconstructed plaintext) only when entering that phase, and dropped the moment the new
    /// deposit succeeds, since nothing needs the plaintext copy after that.
    private(set) var depositViewModel: DepositViewModel?
    private var allContacts: [Contact] = []

    init(secret: Secret, shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        self.secret = secret
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
    }

    var readyToReconstruct: Bool { approvedCount >= secret.k }

    func contactName(_ id: UUID) -> String {
        allContacts.first(where: { $0.id == id })?.displayName ?? String(localized: "Unknown contact")
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let distributed = try shareManagement.listDistributed().filter { $0.secretId == secret.id }
            let contacts = (try? contactManagement.listContacts()) ?? []
            allContacts = contacts
            let requests = try await shareManagement.listSentRequests().filter { $0.secretId == secret.id }
            holderStatuses = distributed.map { share in
                let contact = contacts.first(where: { $0.id == share.contactId })
                let latestRetrieval = contact.flatMap { holder in
                    requests
                        .filter { $0.recipientKey == holder.verifyKey && $0.transactionType == .retrieval }
                        .max { $0.requestedAt < $1.requestedAt }
                }
                return HolderRetrievalStatus(
                    contactId: share.contactId,
                    pseudonym: contact?.displayName ?? String(localized: "Unknown contact"),
                    requestState: latestRetrieval?.state,
                    subtitle: contact.flatMap { $0.nickname != nil ? $0.pseudonym : nil }
                )
            }
            approvedCount = requests.filter {
                $0.transactionType == .retrieval && $0.state == .approved && $0.ciphertext != nil
            }.count
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Opens retrieval requests for any holder of this secret without one already outstanding.
    /// Safe to call repeatedly — `requestAll` never opens a duplicate for a holder that already
    /// has a pending/approved retrieval request for this secret.
    func requestMissingRetrievals() async {
        isActing = true
        defer { isActing = false }
        try? await shareManagement.requestAll(secretId: secret.id)
        await load()
    }

    func reconstruct() async {
        guard readyToReconstruct else { return }
        phase = .reconstructing
        isActing = true
        defer { isActing = false }
        do {
            let result = try await shareManagement.reconstruct(secretId: secret.id)
            reconstructionIntegrity = result.integrity
            let currentHolderIds = Set(holderStatuses.map { $0.contactId })
            // The bytes go through untouched. Decoding them to a String here and re-encoding them
            // on deposit is what used to re-split a corrupted copy of a non-text secret.
            depositViewModel = DepositViewModel(
                shareManagement: shareManagement,
                contactManagement: contactManagement,
                prefill: DepositViewModel.Prefill(
                    label: secret.label,
                    secret: result.secret,
                    mimeType: result.mimeType,
                    selectedContacts: currentHolderIds,
                    threshold: secret.k
                )
            )
            phase = .redeposit
        } catch let ShamirError.reconstructionIntegrityFailed(largestConsistentGroup, totalShares) {
            self.error = String(
                localized: "Reconstruction integrity check failed: no trustworthy majority found among \(totalShares) collected shares (largest consistent group was only \(largestConsistentGroup))."
            )
            phase = .gathering
        } catch {
            self.error = error.localizedDescription
            phase = .gathering
        }
    }

    /// Called once the embedded re-deposit form reports success. Drops the transient
    /// `DepositViewModel` (and with it the only remaining in-memory copy of the reconstructed
    /// plaintext) immediately, since nothing needs it past this point.
    func newDepositSucceeded() {
        depositedHolderCount = depositViewModel?.selectedContacts.count ?? 0
        depositViewModel = nil
        phase = .confirmDiscard
    }

    /// Fans out removal requests to the *old* distribution's holders and flips it to
    /// `.discarding`. Called at most once per flow — `discardSecret` is not idempotent against
    /// repeat calls (each re-opens a fresh removal request per holder), so this phase transition
    /// must never be re-entered after firing.
    func discardOldAndFinish() async {
        isActing = true
        defer { isActing = false }
        try? await shareManagement.discardSecret(secretId: secret.id)
        phase = .done
    }

    func skipDiscard() {
        phase = .done
    }
}

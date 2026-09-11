import hexagon
import Foundation

/// One secret's own screen: its holders, and the three actions that operate on the whole secret
/// rather than on any one holder — asking the holders for copies, putting it back together, and
/// letting the collected copies go again.
///
/// All three stay on screen in every state; what changes is whether they are enabled and what the
/// line beneath them says. The rules themselves live on `SecretGroup`, so the Distributed tab and
/// this screen can never disagree about them.
@Observable
final class SecretDetailViewModel {

    var group: SecretGroup?
    var isLoading = false
    var isRequestingAll = false
    var isReconstructing = false
    var isClearing = false
    var error: String?
    var actionError: String?
    var reconstructed: (secret: ReconstructedSecret, integrity: ReconstructionIntegrity)?

    private let secretId: UUID
    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement
    /// `HolderStatus` carries only ids, so names are resolved against the contact list here — the
    /// same split the Distributed tab makes.
    private var allContacts: [Contact] = []

    init(secretId: UUID, shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        self.secretId = secretId
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
    }

    /// Whether the secret is on screen right now, which is all that is known: `reconstruct` is a
    /// pure read and nothing records that a secret has been looked at. It decides only which of the
    /// two clearing confirmations is shown, and neither claims anything about what the reader
    /// remembers.
    var hasBeenShown: Bool { reconstructed != nil }

    var label: String { group?.secret.label ?? String(localized: "Secret") }
    var mimeType: MimeType { group?.secret.mimeType ?? .default }

    var busy: Bool { isRequestingAll || isReconstructing || isClearing }

    func contactName(_ id: UUID) -> String {
        allContacts.first(where: { $0.id == id })?.displayName ?? String(localized: "Unknown contact")
    }

    /// The contact's pseudonym, shown as a secondary line, but only when `contactName` is actually
    /// a nickname; nil otherwise.
    func contactSubtitle(_ id: UUID) -> String? {
        allContacts.first(where: { $0.id == id }).flatMap { $0.nickname != nil ? $0.pseudonym : nil }
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let secrets = (try? shareManagement.listSecrets()) ?? []
        guard let secret = secrets.first(where: { $0.id == secretId }) else {
            error = String(localized: "Failed to load")
            return
        }
        let distributed = (try? shareManagement.listDistributed()) ?? []
        let requests = (try? await shareManagement.listSentRequests()) ?? []
        allContacts = (try? contactManagement.listContacts()) ?? []
        group = HomeViewModel.buildGroups(
            secrets: [secret],
            distributed: distributed,
            allRequests: requests,
            contacts: allContacts
        ).first
    }

    func requestAll() async {
        isRequestingAll = true
        actionError = nil
        try? await shareManagement.requestAll(secretId: secretId)
        isRequestingAll = false
        await load()
    }

    /// The declared type decides how the bytes are shown, and `ReconstructedSecret` falls back to
    /// a binary view whenever the type and the bytes disagree — so nothing here force-decodes, and
    /// the original bytes survive whichever branch runs.
    func reconstruct() async {
        isReconstructing = true
        actionError = nil
        defer { isReconstructing = false }
        do {
            let result = try await shareManagement.reconstruct(secretId: secretId)
            reconstructed = (
                ReconstructedSecret(secret: result.secret, mimeType: result.mimeType),
                result.integrity
            )
        } catch let ShamirError.reconstructionIntegrityFailed(largestConsistentGroup, totalShares) {
            actionError = String(
                localized: "Reconstruction integrity check failed: no trustworthy majority found among \(totalShares) collected shares (largest consistent group was only \(largestConsistentGroup))."
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Hands the collected copies back — and any ask still waiting for an answer with them —
    /// without touching the split. The holders keep their pieces, so what is on screen goes away
    /// but the secret can be asked for again.
    func clearCollected() async {
        isClearing = true
        actionError = nil
        try? await shareManagement.clearCollectedShares(secretId: secretId)
        reconstructed = nil
        isClearing = false
        await load()
    }

    func destroy() async {
        try? await shareManagement.destroySecret(secretId: secretId)
        await load()
    }

    func forceForget() async {
        try? shareManagement.forceForgetSecret(secretId: secretId)
    }
}

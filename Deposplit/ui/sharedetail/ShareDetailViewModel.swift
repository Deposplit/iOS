import hexagon
import Foundation

enum ReconstructState {
    case unavailable(String)
    case ready
    case reconstructed(ReconstructedSecret, integrity: ReconstructionIntegrity)
    case failed(String)
}

@Observable
final class ShareDetailViewModel {

    var shareRequests: [ShareRequest] = []
    var isLoading = false
    var isActing = false
    var error: String?
    var reconstructState: ReconstructState = .unavailable(String(localized: "Loading…"))

    private let secret: Secret
    private let share: ShareMetadata

    /// Surfaced for the render fork and the export filename — both belong to the secret, not to
    /// the reconstruction, so they are readable before one has happened.
    var mimeType: MimeType { secret.mimeType }
    var label: String { secret.label }
    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement
    private var allContacts: [Contact] = []

    init(target: ShareDetailTarget, shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        self.secret = target.secret
        self.share = target.share
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
    }

    var shareLabel: String { secret.label }
    var recipientName: String {
        allContacts.first(where: { $0.id == share.contactId })?.displayName
            ?? String(localized: "Unknown contact")
    }

    func contactName(_ id: UUID) -> String {
        allContacts.first(where: { $0.id == id })?.displayName ?? String(localized: "Unknown contact")
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let all = try await shareManagement.listSentRequests()
            shareRequests = all.filter { $0.secretId == share.secretId }
            allContacts = (try? contactManagement.listContacts()) ?? []
            updateReconstructState()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func openRequest(type: ShareTransactionType) async {
        isActing = true
        defer { isActing = false }
        do {
            _ = try await shareManagement.openRequest(shareId: share.id, type: type)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The declared type decides how the bytes are shown, and `ReconstructedSecret` falls back to
    /// a binary view whenever the type and the bytes disagree — so nothing here force-decodes, and
    /// the original bytes survive whichever branch runs.
    func reconstruct() async {
        do {
            let result = try await shareManagement.reconstruct(secretId: share.secretId)
            reconstructState = .reconstructed(
                ReconstructedSecret(secret: result.secret, mimeType: result.mimeType),
                integrity: result.integrity
            )
        } catch let ShamirError.reconstructionIntegrityFailed(largestConsistentGroup, totalShares) {
            reconstructState = .failed(String(
                localized: "Reconstruction integrity check failed: no trustworthy majority found among \(totalShares) collected shares (largest consistent group was only \(largestConsistentGroup))."
            ))
        } catch {
            reconstructState = .failed(error.localizedDescription)
        }
    }

    func requestState(for type: ShareTransactionType) -> ShareRequestState? {
        guard let holderKey = allContacts.first(where: { $0.id == share.contactId })?.verifyKey else { return nil }
        return shareRequests
            .filter { $0.recipientKey == holderKey && $0.transactionType == type }
            .sorted { $0.requestedAt > $1.requestedAt }
            .first?.state
    }

    private func updateReconstructState() {
        let approvedCount = shareRequests.filter {
            $0.transactionType == .retrieval && $0.state == .approved && $0.ciphertext != nil
        }.count
        if approvedCount >= secret.k {
            reconstructState = .ready
        } else {
            reconstructState = .unavailable(String(localized: "Need \(secret.k - approvedCount) more approved retrieval(s)."))
        }
    }
}

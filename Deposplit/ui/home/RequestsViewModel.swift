import hexagon
import Foundation

@Observable
final class RequestsViewModel {

    var pendingRequests: [ShareRequest] = []
    var keyConflicts: [KeyConflict] = []
    var isLoading = false
    var error: String?
    var respondingTo: UUID?

    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement
    private var allContacts: [Contact] = []
    private var heldSecretIds: Set<UUID> = []

    init(shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let pending = try await shareManagement.listPendingRequests()
            heldSecretIds = Set(((try? shareManagement.listHeld()) ?? []).map(\.secretId))
            pendingRequests = pending
            allContacts = (try? contactManagement.listContacts()) ?? []
            keyConflicts = (try? shareManagement.listKeyConflicts()) ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }

    func respond(to request: ShareRequest, approve: Bool) async {
        respondingTo = request.id
        defer { respondingTo = nil }
        do {
            try await shareManagement.respond(requestId: request.id, approved: approve)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Approving a retrieval re-encrypts the share to the requester, so it needs the share in hand.
    /// The ask can still arrive after this device deleted it: the owner learns of a withdrawal only
    /// on their next poll, and until then the row has to say why Approve cannot work.
    func canApprove(_ request: ShareRequest) -> Bool {
        request.transactionType != .retrieval || heldSecretIds.contains(request.secretId)
    }

    func senderName(for request: ShareRequest) -> String {
        allContacts.first(where: { $0.verifyKey == request.senderKey })?.displayName
            ?? request.senderKey.base64URLEncoded.prefix(8) + "…"
    }

    // The sender's pseudonym, shown as a secondary line, but only when senderName
    // above is actually a nickname; nil otherwise.
    func senderSubtitle(for request: ShareRequest) -> String? {
        allContacts.first(where: { $0.verifyKey == request.senderKey }).flatMap { $0.nickname != nil ? $0.pseudonym : nil }
    }

    /// Retrieve-approval hardening: the attack signature is *key change → quick
    /// retrieval*, so this is surfaced only for Retrieval requests, not every request type.
    func keyChangedDaysAgo(for request: ShareRequest) -> Int? {
        guard request.transactionType == .retrieval else { return nil }
        guard let contact = allContacts.first(where: { $0.verifyKey == request.senderKey }),
              let changedAt = contact.keyChangedAt else { return nil }
        return Calendar.current.dateComponents([.day], from: changedAt, to: Date()).day
    }

    // MARK: - Key conflicts (never auto-resolved)

    func contactName(for conflict: KeyConflict) -> String {
        allContacts.first(where: { $0.id == conflict.contactId })?.displayName ?? "Unknown contact"
    }

    /// Resolving "yes, this really was them" goes through the existing Relink flow (a fresh
    /// human-verified re-scan), not through this dismiss action — dismissing only acknowledges
    /// the alert (a false alarm, or already handled out-of-band).
    func dismissConflict(_ conflict: KeyConflict) {
        try? shareManagement.dismissKeyConflict(id: conflict.id)
        keyConflicts = (try? shareManagement.listKeyConflicts()) ?? []
    }
}

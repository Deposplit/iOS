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

    init(shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            pendingRequests = try await shareManagement.listPendingRequests()
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

    func senderName(for request: ShareRequest) -> String {
        allContacts.first(where: { $0.edPublicKey == request.senderKey })?.pseudonym
            ?? request.senderKey.base64URLEncoded.prefix(8) + "…"
    }

    /// Item 10's retrieve-approval hardening: the attack signature is *key change → quick
    /// retrieval*, so this is surfaced only for Retrieval requests, not every request type.
    func keyChangedDaysAgo(for request: ShareRequest) -> Int? {
        guard request.transactionType == .retrieval else { return nil }
        guard let contact = allContacts.first(where: { $0.edPublicKey == request.senderKey }),
              let changedAt = contact.keyChangedAt else { return nil }
        return Calendar.current.dateComponents([.day], from: changedAt, to: Date()).day
    }

    // MARK: - Item 10: key conflicts (never auto-resolved)

    func contactName(for conflict: KeyConflict) -> String {
        allContacts.first(where: { $0.id == conflict.contactId })?.pseudonym ?? "Unknown contact"
    }

    /// Resolving "yes, this really was them" goes through the existing Relink flow (a fresh
    /// human-verified re-scan), not through this dismiss action — dismissing only acknowledges
    /// the alert (a false alarm, or already handled out-of-band).
    func dismissConflict(_ conflict: KeyConflict) {
        try? shareManagement.dismissKeyConflict(id: conflict.id)
        keyConflicts = (try? shareManagement.listKeyConflicts()) ?? []
    }
}

import hexagon
import Foundation

@Observable
final class RequestsViewModel {

    var pendingRequests: [ShareRequest] = []
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
}

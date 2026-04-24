import Foundation

@Observable
final class RequestsViewModel {

    var pendingRequests: [ShareRequest] = []
    var isLoading = false
    var error: String?
    var respondingTo: UUID?

    private let transport: ShareTransport
    private let contacts: ContactRepository

    init(transport: ShareTransport, contacts: ContactRepository) {
        self.transport = transport
        self.contacts = contacts
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            pendingRequests = try await transport.listShareRequests(role: .recipient, state: .pending)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func respond(to request: ShareRequest, approve: Bool) async {
        respondingTo = request.id
        defer { respondingTo = nil }
        do {
            _ = try await transport.respondToShareRequest(requestId: request.id, approved: approve)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func senderName(for request: ShareRequest) -> String {
        contacts.getByEdKey(request.share.senderKey)?.pseudonym ?? request.share.senderKey.base64URLEncoded.prefix(8) + "…"
    }
}

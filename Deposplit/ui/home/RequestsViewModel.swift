import hexagon
import Foundation

@Observable
final class RequestsViewModel {

    var pendingRequests: [ShareRequest] = []
    var isLoading = false
    var error: String?
    var respondingTo: UUID?

    private let transport: ShareTransport
    private let contacts: ContactRepository
    private let shareRepository: ShareRepository

    init(transport: ShareTransport, contacts: ContactRepository, shareRepository: ShareRepository) {
        self.transport = transport
        self.contacts = contacts
        self.shareRepository = shareRepository
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
            let ciphertext: Data? = if approve && request.requestType == .retrieve {
                shareRepository.getCiphertext(shareId: request.share.id)
            } else {
                nil
            }
            _ = try await transport.respondToShareRequest(requestId: request.id, approved: approve, ciphertext: ciphertext)
            if approve && request.requestType == .delete {
                shareRepository.delete(shareId: request.share.id)
            }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func senderName(for request: ShareRequest) -> String {
        contacts.getByEdKey(request.share.senderKey)?.pseudonym ?? request.share.senderKey.base64URLEncoded.prefix(8) + "…"
    }
}

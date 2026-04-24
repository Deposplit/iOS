import Foundation

@Observable
final class HomeViewModel {

    var distributedShares: [ShareMetadata] = []
    var heldShares: [ShareMetadata] = []
    var isLoading = false
    var error: String?

    private let transport: ShareTransport
    private let auth: AuthPort

    init(transport: ShareTransport, auth: AuthPort) {
        self.transport = transport
        self.auth = auth
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let sent = transport.listShares(role: .sender, counterpartyKey: nil)
            async let held = transport.listShares(role: .recipient, counterpartyKey: nil)
            (distributedShares, heldShares) = try await (sent, held)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

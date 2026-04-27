import Foundation

@Observable
final class HomeViewModel {

    var distributedShares: [ShareMetadata] = []
    var heldShares: [HeldShare] = []
    var isLoading = false
    var error: String?

    private let transport: ShareTransport
    private let auth: AuthPort
    private let shareRepository: ShareRepository

    init(transport: ShareTransport, auth: AuthPort, shareRepository: ShareRepository) {
        self.transport = transport
        self.auth = auth
        self.shareRepository = shareRepository
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let distributed = try await transport.listShares(role: .sender, counterpartyKey: nil)
            let inbox = try await transport.listShares(role: .recipient, counterpartyKey: nil)
            for meta in inbox {
                if shareRepository.getCiphertext(shareId: meta.id) == nil {
                    if let ct = try? await transport.pickUpShare(shareId: meta.id) {
                        shareRepository.save(HeldShare(
                            id: meta.id,
                            secretId: meta.secretId,
                            label: meta.label,
                            senderKey: meta.senderKey,
                            createdAt: meta.createdAt,
                            ciphertext: ct
                        ))
                    }
                }
            }
            distributedShares = distributed
            heldShares = shareRepository.getAll()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

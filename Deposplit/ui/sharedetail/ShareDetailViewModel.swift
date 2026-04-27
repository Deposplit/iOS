import Foundation

enum ReconstructState {
    case unavailable(String)
    case ready
    case reconstructed(String)
    case failed(String)
}

@Observable
final class ShareDetailViewModel {

    var shareRequests: [ShareRequest] = []
    var isLoading = false
    var isActing = false
    var error: String?
    var reconstructState: ReconstructState = .unavailable("Loading…")

    private let share: ShareMetadata
    private let auth: AuthPort
    private let transport: ShareTransport
    private let contacts: ContactRepository

    init(share: ShareMetadata, auth: AuthPort, transport: ShareTransport, contacts: ContactRepository) {
        self.share = share
        self.auth = auth
        self.transport = transport
        self.contacts = contacts
    }

    var shareLabel: String { share.label }
    var recipientName: String {
        contacts.getByEdKey(share.recipientKey)?.pseudonym
            ?? share.recipientKey.base64URLEncoded.prefix(8) + "…"
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let all = try await transport.listShareRequests(role: .sender, state: nil)
            shareRequests = all.filter { $0.share.secretId == share.secretId }
            updateReconstructState()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func openRequest(type: ShareRequestType) async {
        isActing = true
        defer { isActing = false }
        do {
            _ = try await transport.openShareRequest(shareId: share.id, type: type)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reconstruct() async -> String? {
        let approvedRetrieves = shareRequests.filter {
            $0.requestType == .retrieve && $0.state == .approved && $0.ciphertext != nil
        }
        guard approvedRetrieves.count >= 2 else {
            reconstructState = .unavailable("Need at least 2 approved retrieve requests.")
            return nil
        }
        do {
            let decryptedShares: [[UInt8]] = try approvedRetrieves.map { req in
                let ct = req.ciphertext!
                guard let contact = contacts.getByEdKey(req.share.recipientKey) else {
                    throw NSError(domain: "Deposplit", code: 0,
                                  userInfo: [NSLocalizedDescriptionKey: "Contact not found for recipient — cannot decrypt share"])
                }
                let plaintext = try auth.decrypt(ct, recipientXPublicKey: contact.xPublicKey)
                return Array(plaintext)
            }
            let secretBytes = try combine(shares: decryptedShares)
            let secret = String(bytes: secretBytes, encoding: .utf8) ?? Data(secretBytes).base64EncodedString()
            reconstructState = .reconstructed(secret)
            for req in approvedRetrieves {
                try? await transport.deleteShare(shareId: req.share.id)
            }
            return secret
        } catch {
            reconstructState = .failed(error.localizedDescription)
            return nil
        }
    }

    func requestState(for type: ShareRequestType) -> ShareRequestState? {
        shareRequests
            .filter { $0.share.id == share.id && $0.requestType == type }
            .sorted { $0.requestedAt > $1.requestedAt }
            .first?.state
    }

    private func updateReconstructState() {
        let approvedCount = shareRequests.filter {
            $0.requestType == .retrieve && $0.state == .approved && $0.ciphertext != nil
        }.count
        if approvedCount >= 2 {
            reconstructState = .ready
        } else {
            reconstructState = .unavailable("Need \(2 - approvedCount) more approved retrieval(s).")
        }
    }
}

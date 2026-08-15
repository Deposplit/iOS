import hexagon
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
    var reconstructState: ReconstructState = .unavailable(String(localized: "Loading…"))

    private let share: ShareMetadata
    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement
    private var allContacts: [Contact] = []

    init(share: ShareMetadata, shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        self.share = share
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
    }

    var shareLabel: String { share.label }
    var recipientName: String {
        allContacts.first(where: { $0.id == share.contactId })?.pseudonym
            ?? String(localized: "Unknown contact")
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

    func openRequest(type: ShareRequestType) async {
        isActing = true
        defer { isActing = false }
        do {
            _ = try await shareManagement.openRequest(shareId: share.id, type: type)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reconstruct() async -> String? {
        do {
            let secretData = try await shareManagement.reconstruct(secretId: share.secretId)
            let secret = String(bytes: Array(secretData), encoding: .utf8)
                ?? secretData.base64EncodedString()
            reconstructState = .reconstructed(secret)
            return secret
        } catch {
            reconstructState = .failed(error.localizedDescription)
            return nil
        }
    }

    func requestState(for type: ShareRequestType) -> ShareRequestState? {
        shareRequests
            .filter { $0.shareId == share.id && $0.requestType == type }
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
            reconstructState = .unavailable(String(localized: "Need \(2 - approvedCount) more approved retrieval(s)."))
        }
    }
}

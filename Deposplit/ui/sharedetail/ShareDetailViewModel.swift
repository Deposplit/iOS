import hexagon
import Foundation

@Observable
final class ShareDetailViewModel {

    var shareRequests: [ShareRequest] = []
    var isLoading = false
    var isActing = false
    var error: String?

    private let secret: Secret
    private let share: ShareMetadata

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

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let all = try await shareManagement.listSentRequests()
            shareRequests = all.filter { $0.secretId == share.secretId }
            allContacts = (try? contactManagement.listContacts()) ?? []
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

    func requestState(for type: ShareTransactionType) -> ShareRequestState? {
        guard let holderKey = allContacts.first(where: { $0.id == share.contactId })?.verifyKey else { return nil }
        return shareRequests
            .filter { $0.recipientKey == holderKey && $0.transactionType == type }
            .sorted { $0.requestedAt > $1.requestedAt }
            .first?.state
    }
}

import hexagon
import Foundation

@Observable
final class HomeViewModel {

    var distributedShares: [ShareMetadata] = []
    var heldShares: [HeldShare] = []
    var isLoading = false
    var error: String?

    private let shareManagement: any ShareManagement

    init(shareManagement: any ShareManagement) {
        self.shareManagement = shareManagement
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            try await shareManagement.syncInbox()
            distributedShares = try await shareManagement.listDistributed()
            heldShares = try await shareManagement.listHeld()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

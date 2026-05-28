import hexagon
import Foundation

@Observable
final class HomeViewModel {

    var distributedShares: [ShareMetadata] = []
    var heldShares: [HeldShare] = []
    var isLoading = false
    var syncWarning = false
    var error: String?

    private let shareManagement: any ShareManagement

    init(shareManagement: any ShareManagement) {
        self.shareManagement = shareManagement
    }

    func load() async {
        isLoading = true
        error = nil
        syncWarning = false

        // Phase 1: local data only — renders immediately even when offline
        do {
            distributedShares = try shareManagement.listDistributed()
            heldShares = try shareManagement.listHeld()
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            return
        }
        isLoading = false

        // Phase 2: relay sync — soft failure, never wipes Phase 1 results
        do {
            try await shareManagement.syncInbox()
            try await shareManagement.syncDistributed()
            distributedShares = try shareManagement.listDistributed()
            heldShares = try shareManagement.listHeld()
        } catch {
            syncWarning = true
        }
    }
}

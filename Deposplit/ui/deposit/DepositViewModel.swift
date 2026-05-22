import hexagon
import Foundation

@Observable
final class DepositViewModel {

    var label = ""
    var secretText = ""
    var selectedContacts: Set<UUID> = []
    var threshold = 2
    var isDepositing = false
    var error: String?
    var depositedSuccessfully = false

    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement

    init(shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
    }

    var allContacts: [Contact] { (try? contactManagement.listContacts()) ?? [] }

    var canDeposit: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty &&
        !secretText.isEmpty &&
        selectedContacts.count >= 2 &&
        threshold >= 2 &&
        threshold <= selectedContacts.count
    }

    func deposit() async {
        guard canDeposit else { return }
        isDepositing = true
        error = nil
        defer { isDepositing = false }
        do {
            let chosen = allContacts.filter { selectedContacts.contains($0.id) }
            try await shareManagement.deposit(
                secret: Data(secretText.utf8),
                label: label.trimmingCharacters(in: .whitespaces),
                contacts: chosen,
                threshold: threshold
            )
            depositedSuccessfully = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

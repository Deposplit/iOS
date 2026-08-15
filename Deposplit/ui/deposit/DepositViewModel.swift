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

    /// Non-blocking "Are you sure?" warnings across item 11's three soft axes — operational
    /// burden, confidentiality tail, and availability tail. Thresholds/wording are UI tuning,
    /// not load-bearing spec — see deposplit.com/CLAUDE.md "What is next" item 11.
    var splitTimeWarnings: [String] {
        Self.splitTimeWarnings(k: threshold, n: selectedContacts.count)
    }

    static func splitTimeWarnings(k: Int, n: Int) -> [String] {
        guard n > 0 else { return [] }
        var warnings: [String] = []
        if n >= 20 {
            warnings.append(String(localized: "Distributing to \(n) people is a lot to manage — you'll need to exchange keys, approve every pickup, and keep track of all of them."))
        } else if n >= 10 {
            warnings.append(String(localized: "Distributing to \(n) people is more holders than usual to keep track of."))
        }
        if k < n / 3 {
            warnings.append(String(localized: "Only \(k) of \(n) holders need to cooperate to reconstruct this secret — a small group could do so without your knowledge."))
        } else if k < n / 2 {
            warnings.append(String(localized: "\(k) of \(n) is a relatively low threshold — a minority of holders could reconstruct this secret together."))
        }
        if k == n {
            warnings.append(String(localized: "Every single holder must be available — if even one loses their share, this secret becomes unrecoverable."))
        } else if k == n - 1 {
            warnings.append(String(localized: "This tolerates the loss of only one holder before the secret becomes unrecoverable."))
        }
        return warnings
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

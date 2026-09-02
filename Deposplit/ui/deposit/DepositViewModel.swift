import hexagon
import Foundation

@Observable
final class DepositViewModel {

    /// Seeds the form's initial state — used by the Repair flow to pre-fill a reconstructed
    /// secret's label/value/holders/threshold into an otherwise-ordinary deposit. All fields
    /// stay editable afterward; this only affects the starting values.
    ///
    /// The secret arrives as **bytes**, not a `String`. Round-tripping it through text is what
    /// used to corrupt a non-text secret on re-split: it was decoded lossily (or to base64) and
    /// then re-encoded, so the repair wrote back something other than what it reconstructed.
    struct Prefill {
        let label: String
        let secret: Data
        let mimeType: MimeType
        let selectedContacts: Set<UUID>
        let threshold: Int
    }

    /// What this form will actually split. Text is edited in the field; anything else is carried
    /// through verbatim, because there is no sensible way to edit it in a text field and
    /// re-encoding it as a `String` is exactly the corruption above.
    enum Payload {
        case text
        case opaque(Data)
    }

    var label = ""
    var secretText = ""
    var selectedContacts: Set<UUID> = []
    var threshold = 2
    var isDepositing = false
    var error: String?
    var depositedSuccessfully = false

    /// Everything the app can compose today is typed text; a prefill is the only way this becomes
    /// anything else, and only by carrying through what a reconstruction produced.
    private(set) var payload: Payload = .text
    private(set) var mimeType: MimeType = .default

    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement

    init(shareManagement: any ShareManagement, contactManagement: any ContactManagement, prefill: Prefill? = nil) {
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
        if let prefill {
            self.label = prefill.label
            self.selectedContacts = prefill.selectedContacts
            self.threshold = prefill.threshold
            self.mimeType = prefill.mimeType
            // Editable only when it really is text — a declared text type whose bytes are not
            // valid UTF-8 is carried through opaquely rather than mangled into the field.
            if prefill.mimeType.isText, let text = String(data: prefill.secret, encoding: .utf8) {
                self.secretText = text
                self.payload = .text
            } else {
                self.payload = .opaque(prefill.secret)
            }
        }
    }

    var allContacts: [Contact] { (try? contactManagement.listContacts()) ?? [] }

    /// The bytes this form will split — the edited text, or the prefilled payload untouched.
    var secretBytes: Data {
        switch payload {
        case .text: Data(secretText.utf8)
        case .opaque(let data): data
        }
    }

    /// True when the payload came through a repair and cannot be shown in the text field.
    var isOpaquePayload: Bool {
        if case .opaque = payload { return true }
        return false
    }

    var canDeposit: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty &&
        !secretBytes.isEmpty &&
        selectedContacts.count >= 2 &&
        threshold >= 2 &&
        threshold <= selectedContacts.count
    }

    /// Non-blocking "Are you sure?" warnings across the three soft axes of choosing k and n —
    /// operational burden, confidentiality tail, and availability tail. Thresholds and wording
    /// are UI tuning, not load-bearing spec.
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
                secret: secretBytes,
                label: label.trimmingCharacters(in: .whitespaces),
                contacts: chosen,
                threshold: threshold,
                mimeType: mimeType
            )
            depositedSuccessfully = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

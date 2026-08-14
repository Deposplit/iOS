import hexagon
import Foundation

@Observable
final class AddContactViewModel {

    var pseudonym = ""
    var edKeyInput = ""
    var xKeyInput = ""
    var relayBaseUrlInput = ""
    var verificationLevel: VerificationLevel = .veryLow
    var error: String?

    /// `.veryHigh` requires physical co-presence, which manual key entry can't assert — that's
    /// what the in-person QR scan flow is for. See CLAUDE.md item 6.
    let selectableLevels = VerificationLevel.allCases.filter { $0 != .veryHigh }

    private let contactManagement: any ContactManagement

    init(contactManagement: any ContactManagement) {
        self.contactManagement = contactManagement
    }

    func save() -> Bool {
        guard !pseudonym.trimmingCharacters(in: .whitespaces).isEmpty
            else { error = String(localized: "Name is required."); return false }
        guard let ed = Data(base64URLEncoded: edKeyInput.trimmingCharacters(in: .whitespaces)),
              ed.count == 32
            else { error = String(localized: "Invalid Ed25519 key (expected 32 bytes, base64url)."); return false }
        guard let x = Data(base64URLEncoded: xKeyInput.trimmingCharacters(in: .whitespaces)),
              x.count == 32
            else { error = String(localized: "Invalid X25519 key (expected 32 bytes, base64url)."); return false }
        let trimmedRelay = relayBaseUrlInput.trimmingCharacters(in: .whitespaces)
        do {
            try contactManagement.addManually(pseudonym: pseudonym, edPublicKey: ed, xPublicKey: x, verificationLevel: verificationLevel, relayBaseUrl: trimmedRelay.isEmpty ? nil : trimmedRelay)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

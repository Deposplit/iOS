import hexagon
import Foundation

@Observable
final class AddContactViewModel {

    var pseudonym = ""
    var verifyKeyInput = ""
    var encKeyInput = ""
    var relayBaseUrlInput = ""
    var nicknameInput = ""
    var verificationLevel: VerificationLevel = .veryLow
    var error: String?

    /// `.veryHigh` requires physical co-presence, which manual key entry can't assert — that's
    /// what the in-person QR scan flow is for.
    let selectableLevels = VerificationLevel.allCases.filter { $0 != .veryHigh }

    private let contactManagement: any ContactManagement

    init(contactManagement: any ContactManagement) {
        self.contactManagement = contactManagement
    }

    func save() -> Bool {
        guard !pseudonym.trimmingCharacters(in: .whitespaces).isEmpty
            else { error = String(localized: "Name is required."); return false }
        guard let verifyKey = Data(base64URLEncoded: verifyKeyInput.trimmingCharacters(in: .whitespaces)),
              verifyKey.count == 32
            else { error = String(localized: "Invalid verify key (expected 32 bytes, base64url)."); return false }
        guard let encKey = Data(base64URLEncoded: encKeyInput.trimmingCharacters(in: .whitespaces)),
              encKey.count == 32
            else { error = String(localized: "Invalid encryption key (expected 32 bytes, base64url)."); return false }
        let trimmedRelay = relayBaseUrlInput.trimmingCharacters(in: .whitespaces)
        let trimmedNickname = nicknameInput.trimmingCharacters(in: .whitespaces)
        do {
            try contactManagement.addManually(
                pseudonym: pseudonym,
                verifyKey: verifyKey,
                encKey: encKey,
                verificationLevel: verificationLevel,
                relayBaseUrl: trimmedRelay.isEmpty ? nil : trimmedRelay,
                nickname: trimmedNickname.isEmpty ? nil : trimmedNickname
            )
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

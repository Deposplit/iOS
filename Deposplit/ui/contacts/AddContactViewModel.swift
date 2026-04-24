import Foundation

@Observable
final class AddContactViewModel {

    var pseudonym = ""
    var edKeyInput = ""
    var xKeyInput = ""
    var error: String?

    private let repository: ContactRepository

    init(repository: ContactRepository) {
        self.repository = repository
    }

    func save() -> Bool {
        let name = pseudonym.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { error = "Name is required."; return false }
        guard let ed = Data(base64URLEncoded: edKeyInput.trimmingCharacters(in: .whitespaces)),
              ed.count == 32 else { error = "Invalid Ed25519 key (expected 32 bytes, base64url)."; return false }
        guard let x = Data(base64URLEncoded: xKeyInput.trimmingCharacters(in: .whitespaces)),
              x.count == 32 else { error = "Invalid X25519 key (expected 32 bytes, base64url)."; return false }
        let contact = Contact(
            id: UUID(),
            pseudonym: name,
            edPublicKey: ed,
            xPublicKey: x,
            verificationLevel: .unverified,
            verifiedAt: nil,
            addedAt: ISO8601DateFormatter().string(from: Date())
        )
        repository.save(contact)
        return true
    }

    func saveFromQR(payload: QrPayload) -> Bool {
        guard let ed = Data(base64URLEncoded: payload.ed),
              let x = Data(base64URLEncoded: payload.x) else {
            error = "Invalid keys in QR payload."
            return false
        }
        let contact = Contact(
            id: UUID(),
            pseudonym: payload.pseudonym,
            edPublicKey: ed,
            xPublicKey: x,
            verificationLevel: .verified,
            verifiedAt: ISO8601DateFormatter().string(from: Date()),
            addedAt: ISO8601DateFormatter().string(from: Date())
        )
        repository.save(contact)
        return true
    }
}

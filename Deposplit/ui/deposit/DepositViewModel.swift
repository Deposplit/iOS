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

    private let auth: Identity
    private let transport: ShareTransport
    private let contacts: ContactRepository

    init(auth: Identity, transport: ShareTransport, contacts: ContactRepository) {
        self.auth = auth
        self.transport = transport
        self.contacts = contacts
    }

    var allContacts: [Contact] { contacts.getAll() }

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
            let secretBytes = Array(secretText.utf8)
            let chosen = contacts.getAll().filter { selectedContacts.contains($0.id) }
            let shares = try split(secret: secretBytes, shares: chosen.count, threshold: threshold)
            let secretId = UUID()

            for (contact, share) in zip(chosen, shares) {
                let plaintext = Data(share)
                let ciphertext = try auth.encrypt(plaintext, recipientXPublicKey: contact.xPublicKey)
                _ = try await transport.depositShare(
                    secretId: secretId,
                    label: label.trimmingCharacters(in: .whitespaces),
                    recipientKey: contact.edPublicKey,
                    ciphertext: ciphertext
                )
            }
            depositedSuccessfully = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

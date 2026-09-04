import hexagon
import Foundation

/// Re-registration after a phone switch. Deliberately the same call as first registration —
/// `Identity.register` mints a fresh identity and leaves contacts, secrets, share metadata and the
/// shares held for other people exactly where they are, so there is nothing to weigh up before
/// pressing the button.
///
/// The pseudonym is pre-filled from storage because it survived the switch along with everything
/// else; only the keys did not.
@Observable
final class KeysLostViewModel {

    var pseudonym: String
    var isLoading = false
    var error: String?

    private let auth: any Identity

    init(auth: any Identity) {
        self.auth = auth
        self.pseudonym = auth.pseudonym
    }

    func createNewKeys() {
        let name = pseudonym.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { error = "Please enter a name."; return }
        isLoading = true
        error = nil
        do {
            try auth.register(pseudonym: name)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

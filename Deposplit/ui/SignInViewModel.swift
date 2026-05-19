import hexagon
import Foundation

@Observable
final class SignInViewModel {

    var pseudonym = ""
    var isLoading = false
    var error: String?

    private let auth: any Identity

    init(auth: any Identity) {
        self.auth = auth
    }

    func register() {
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

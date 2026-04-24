import SwiftUI

@main
struct DeposplitApp: App {
    private let auth: DeposplitAuthAdapter
    private let contacts: LocalContactRepository
    private let transport: DeposplitApiAdapter

    init() {
        let a = DeposplitAuthAdapter()
        auth = a
        contacts = LocalContactRepository()
        #if DEBUG
        transport = DeposplitApiAdapter(auth: a, baseURL: "http://localhost:9000")
        #else
        transport = DeposplitApiAdapter(auth: a)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth, transport: transport, contacts: contacts)
        }
    }
}

struct RootView: View {
    let auth: AuthPort
    let transport: ShareTransport
    let contacts: ContactRepository
    @State private var isRegistered: Bool

    init(auth: AuthPort, transport: ShareTransport, contacts: ContactRepository) {
        self.auth = auth
        self.transport = transport
        self.contacts = contacts
        _isRegistered = State(initialValue: auth.isRegistered)
    }

    var body: some View {
        if isRegistered {
            HomeView(auth: auth, transport: transport, contacts: contacts)
        } else {
            SignInView(auth: auth) {
                isRegistered = true
            }
        }
    }
}

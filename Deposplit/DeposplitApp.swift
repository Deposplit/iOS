import hexagon
import SwiftUI

@main
struct DeposplitApp: App {
    private let auth: any Identity
    private let contacts: LocalContactRepository
    private let transport: DeposplitApiAdapter
    private let shareRepository: LocalShareRepository

    init() {
        let a = IdentityService(identityStore: KeychainIdentityStore())
        auth = a
        contacts = LocalContactRepository()
        shareRepository = LocalShareRepository()
        #if DEBUG
        transport = DeposplitApiAdapter(auth: a, baseURL: "http://localhost:9000")
        #else
        transport = DeposplitApiAdapter(auth: a)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth, transport: transport, contacts: contacts, shareRepository: shareRepository)
        }
    }
}

struct RootView: View {
    let auth: Identity
    let transport: ShareTransport
    let contacts: ContactRepository
    let shareRepository: ShareRepository
    @State private var isRegistered: Bool

    init(auth: Identity, transport: ShareTransport, contacts: ContactRepository, shareRepository: ShareRepository) {
        self.auth = auth
        self.transport = transport
        self.contacts = contacts
        self.shareRepository = shareRepository
        _isRegistered = State(initialValue: auth.isRegistered)
    }

    var body: some View {
        if isRegistered {
            HomeView(auth: auth, transport: transport, contacts: contacts, shareRepository: shareRepository)
        } else {
            SignInView(auth: auth) {
                isRegistered = true
            }
        }
    }
}

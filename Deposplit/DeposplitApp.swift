import hexagon
import SwiftUI

@main
struct DeposplitApp: App {
    private let auth: any Identity
    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement

    init() {
        let identityService = IdentityService(identityStore: KeychainIdentityStore())
        auth = identityService
        let contactRepository = LocalContactRepository()
        let shareRepository = LocalShareRepository()
        let shareMetadataRepository = LocalShareMetadataRepository()
        #if DEBUG
        let relay = DeposplitApiAdapter(signer: identityService, baseURL: "http://localhost:9000")
        #else
        let relay = DeposplitApiAdapter(signer: identityService)
        #endif
        shareManagement = ShareService(
            relay: relay,
            encryption: identityService,
            shareRepository: shareRepository,
            shareMetadataRepository: shareMetadataRepository,
            contactRepository: contactRepository
        )
        contactManagement = ContactService(contactRepository: contactRepository)
    }

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth, shareManagement: shareManagement, contactManagement: contactManagement)
        }
    }
}

struct RootView: View {
    let auth: any Identity
    let shareManagement: any ShareManagement
    let contactManagement: any ContactManagement
    @State private var isRegistered: Bool

    init(auth: any Identity, shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        self.auth = auth
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
        _isRegistered = State(initialValue: auth.isRegistered)
    }

    var body: some View {
        if isRegistered {
            HomeView(auth: auth, shareManagement: shareManagement, contactManagement: contactManagement)
        } else {
            SignInView(auth: auth) {
                isRegistered = true
            }
        }
    }
}

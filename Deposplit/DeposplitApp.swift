import hexagon
import SwiftUI

@main
struct DeposplitApp: App {
    private let auth: any Identity
    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement
    private let relaySettings: any RelaySettings

    init() {
        let identityService = IdentityService(identityStore: KeychainIdentityStore())
        auth = identityService
        relaySettings = UserDefaultsRelaySettings()
        let contactRepository = LocalContactRepository()
        let shareRepository = LocalShareRepository()
        let shareMetadataRepository = LocalShareMetadataRepository()
        let relayResolver = DeposplitRelayResolver(identity: identityService, relaySettings: relaySettings)
        shareManagement = ShareService(
            relayResolver: relayResolver,
            encryption: identityService,
            shareRepository: shareRepository,
            shareMetadataRepository: shareMetadataRepository,
            contactRepository: contactRepository,
            identity: identityService
        )
        contactManagement = ContactService(contactRepository: contactRepository)
    }

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth, shareManagement: shareManagement, contactManagement: contactManagement, relaySettings: relaySettings)
        }
    }
}

struct RootView: View {
    let auth: any Identity
    let shareManagement: any ShareManagement
    let contactManagement: any ContactManagement
    let relaySettings: any RelaySettings
    @State private var isRegistered: Bool

    init(auth: any Identity, shareManagement: any ShareManagement, contactManagement: any ContactManagement, relaySettings: any RelaySettings) {
        self.auth = auth
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
        self.relaySettings = relaySettings
        _isRegistered = State(initialValue: auth.isRegistered)
    }

    var body: some View {
        if isRegistered {
            HomeView(auth: auth, shareManagement: shareManagement, contactManagement: contactManagement, relaySettings: relaySettings)
        } else {
            SignInView(auth: auth) {
                isRegistered = true
            }
        }
    }
}

import hexagon
import SwiftUI

@main
struct DeposplitApp: App {
    private let auth: any Identity
    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement
    private let catalogManagement: any CatalogManagement
    private let relaySettings: any RelaySettings
    private let purchaseStore: StoreKitPurchaseStore
    private let custodyRefresh: CustodyRefresh

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let identityStore = KeychainIdentityStore()
        let identityService = IdentityService(identityStore: identityStore)
        auth = identityService
        relaySettings = UserDefaultsRelaySettings()
        let purchaseRepository = UserDefaultsPurchaseRepository()
        purchaseStore = StoreKitPurchaseStore(cache: purchaseRepository)
        let contactRepository = LocalContactRepository()
        let shareRepository = LocalShareRepository()
        let shareMetadataRepository = LocalShareMetadataRepository()
        let secretRepository = LocalSecretRepository()
        let keyConflictRepository = LocalKeyConflictRepository()
        let retainedDepositRepository = LocalRetainedDepositRepository()
        let relayResolver = DeposplitRelayResolver(identity: identityService, relaySettings: relaySettings)
        let contactService = ContactService(
            contactRepository: contactRepository,
            purchases: purchaseRepository,
            identityStore: identityStore,
            relinkRepository: LocalContactRelinkRepository()
        )
        contactManagement = contactService
        let shareService = ShareService(
            relayResolver: relayResolver,
            encryption: identityService,
            shareRepository: shareRepository,
            shareMetadataRepository: shareMetadataRepository,
            secretRepository: secretRepository,
            contactRepository: contactRepository,
            contactManagement: contactService,
            keyConflictRepository: keyConflictRepository,
            retainedDepositRepository: retainedDepositRepository,
            identity: identityService,
            purchases: purchaseRepository
        )
        shareManagement = shareService
        custodyRefresh = CustodyRefresh(auth: identityService, shareManagement: shareService)
        catalogManagement = CatalogService(
            contactRepository: contactRepository,
            secretRepository: secretRepository,
            shareMetadataRepository: shareMetadataRepository
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth, shareManagement: shareManagement, contactManagement: contactManagement, catalogManagement: catalogManagement, relaySettings: relaySettings, purchaseStore: purchaseStore, custodyRefresh: custodyRefresh)
                // At launch rather than in `init`, because the scene — and with it the task
                // registration below — has to exist before a request for it can be accepted.
                .task { custodyRefresh.submit() }
        }
        // Registers the pass as well as running it. The closure is the only place this app does
        // anything while nobody is looking at it.
        .backgroundTask(.appRefresh(CustodyRefresh.taskIdentifier)) {
            await custodyRefresh.runPass()
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving is the moment a refresh becomes worth asking for; the request made at launch
            // has by now been pushed a day out by every launch since.
            if phase == .background { custodyRefresh.submit() }
        }
    }
}

struct RootView: View {
    let auth: any Identity
    let shareManagement: any ShareManagement
    let contactManagement: any ContactManagement
    let catalogManagement: any CatalogManagement
    let relaySettings: any RelaySettings
    let purchaseStore: StoreKitPurchaseStore
    let custodyRefresh: CustodyRefresh
    @State private var isRegistered: Bool
    @State private var keysLost: Bool

    init(auth: any Identity, shareManagement: any ShareManagement, contactManagement: any ContactManagement, catalogManagement: any CatalogManagement, relaySettings: any RelaySettings, purchaseStore: StoreKitPurchaseStore, custodyRefresh: CustodyRefresh) {
        self.auth = auth
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
        self.catalogManagement = catalogManagement
        self.relaySettings = relaySettings
        self.purchaseStore = purchaseStore
        self.custodyRefresh = custodyRefresh
        _isRegistered = State(initialValue: auth.isRegistered)
        // `.unreadable` deliberately falls through to Home: key storage that is merely locked must
        // never be offered a replacement identity.
        _keysLost = State(initialValue: auth.isRegistered && auth.integrity == .keysLost)
    }

    var body: some View {
        if !isRegistered {
            SignInView(auth: auth) {
                isRegistered = true
                // This launch created the identity, so the request made when the scene appeared
                // had nothing to schedule for.
                custodyRefresh.submit()
            }
        } else if keysLost {
            KeysLostView(auth: auth) {
                keysLost = false
            }
        } else {
            HomeView(auth: auth, shareManagement: shareManagement, contactManagement: contactManagement, catalogManagement: catalogManagement, relaySettings: relaySettings, purchaseStore: purchaseStore)
        }
    }
}

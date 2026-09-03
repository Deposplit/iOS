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

    init() {
        let identityService = IdentityService(identityStore: KeychainIdentityStore())
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
        let contactService = ContactService(contactRepository: contactRepository, purchases: purchaseRepository)
        contactManagement = contactService
        shareManagement = ShareService(
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
        catalogManagement = CatalogService(
            contactRepository: contactRepository,
            secretRepository: secretRepository,
            shareMetadataRepository: shareMetadataRepository
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth, shareManagement: shareManagement, contactManagement: contactManagement, catalogManagement: catalogManagement, relaySettings: relaySettings, purchaseStore: purchaseStore)
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
    @State private var isRegistered: Bool

    init(auth: any Identity, shareManagement: any ShareManagement, contactManagement: any ContactManagement, catalogManagement: any CatalogManagement, relaySettings: any RelaySettings, purchaseStore: StoreKitPurchaseStore) {
        self.auth = auth
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
        self.catalogManagement = catalogManagement
        self.relaySettings = relaySettings
        self.purchaseStore = purchaseStore
        _isRegistered = State(initialValue: auth.isRegistered)
    }

    var body: some View {
        if isRegistered {
            HomeView(auth: auth, shareManagement: shareManagement, contactManagement: contactManagement, catalogManagement: catalogManagement, relaySettings: relaySettings, purchaseStore: purchaseStore)
        } else {
            SignInView(auth: auth) {
                isRegistered = true
            }
        }
    }
}

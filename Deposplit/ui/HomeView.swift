import hexagon
import SwiftUI

struct HomeView: View {
    private let auth: any Identity
    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement
    private let catalogManagement: any CatalogManagement
    private let relaySettings: any RelaySettings
    private let purchaseStore: StoreKitPurchaseStore

    @State private var homeViewModel: HomeViewModel
    @State private var requestsViewModel: RequestsViewModel
    @State private var allContacts: [Contact] = []
    @State private var selectedTab = 0
    @State private var showContacts = false
    @State private var showQrDisplay = false
    @State private var showDeposit = false
    @State private var showSettings = false
    @State private var selectedShareTarget: ShareDetailTarget?
    @State private var selectedSecret: Secret?
    @State private var repairSecret: Secret?
    @State private var showNotificationExplanation = false

    init(auth: any Identity, shareManagement: any ShareManagement, contactManagement: any ContactManagement, catalogManagement: any CatalogManagement, relaySettings: any RelaySettings, purchaseStore: StoreKitPurchaseStore) {
        self.auth = auth
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
        self.catalogManagement = catalogManagement
        self.relaySettings = relaySettings
        self.purchaseStore = purchaseStore
        _homeViewModel = State(initialValue: HomeViewModel(shareManagement: shareManagement, contactManagement: contactManagement))
        _requestsViewModel = State(initialValue: RequestsViewModel(
            shareManagement: shareManagement,
            contactManagement: contactManagement
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if homeViewModel.awaitingRelinkCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .imageScale(.small)
                        Text(
                            homeViewModel.awaitingRelinkCount == 1
                                ? "1 contact still has your old key — meet them and let them re-scan your code"
                                : "\(homeViewModel.awaitingRelinkCount) contacts still have your old key — meet them and let them re-scan your code"
                        )
                        .font(.caption)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.bar)
                    Divider()
                }
                if homeViewModel.syncWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .imageScale(.small)
                        Text("Relay not reachable")
                            .font(.caption)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.bar)
                    Divider()
                }
                TabView(selection: $selectedTab) {
                    Tab("Split & shared", systemImage: "photo.stack.fill", value: 0) {
                        distributedContent
                    }
                    Tab("Keeping safe", systemImage: "puzzlepiece.fill", value: 1) {
                        heldContent
                    }
                    Tab("Requests", systemImage: "checklist", value: 2) {
                        RecipientRequestsTab(viewModel: requestsViewModel)
                    }
                }
            }
            .navigationTitle(tabTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showContacts = true
                    } label: {
                        Image(systemName: "person.2")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showQrDisplay = true
                    } label: {
                        Image(systemName: "qrcode")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack {
                        Button {
                            showDeposit = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        Button {
                            Task {
                                await reload()
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .tint(homeViewModel.syncWarning ? .red : .accentColor)
                    }
                }
            }
            .navigationDestination(item: $selectedSecret) { secret in
                SecretDetailView(
                    secretId: secret.id,
                    shareManagement: shareManagement,
                    contactManagement: contactManagement,
                    onTapHolder: { selectedShareTarget = $0 },
                    onRepair: { repairSecret = $0 }
                )
            }
            .navigationDestination(item: $selectedShareTarget) { target in
                ShareDetailView(target: target, shareManagement: shareManagement, contactManagement: contactManagement)
            }
        }
        .sheet(isPresented: $showContacts, onDismiss: { loadContacts() }) {
            ContactsView(contactManagement: contactManagement, shareManagement: shareManagement)
        }
        .sheet(isPresented: $showQrDisplay) {
            QrDisplayView(auth: auth, relaySettings: relaySettings)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(relaySettings: relaySettings, catalogManagement: catalogManagement, shareManagement: shareManagement, contactManagement: contactManagement, purchaseStore: purchaseStore)
        }
        .sheet(isPresented: $showDeposit, onDismiss: {
            Task { await homeViewModel.load() }
        }) {
            DepositView(shareManagement: shareManagement, contactManagement: contactManagement, purchaseStore: purchaseStore)
        }
        .sheet(item: $repairSecret, onDismiss: {
            Task { await homeViewModel.load() }
        }) { secret in
            RepairView(
                secret: secret,
                shareManagement: shareManagement,
                contactManagement: contactManagement,
                purchases: purchaseStore,
                onFinished: { repairSecret = nil }
            )
        }
        .task {
            await reload()
        }
        // Asked at the first moment it could ever mean anything: this phone is now keeping
        // something for somebody, so a request for it can arrive. Asking at first launch would be
        // a dialog about a notice that cannot exist yet, and this app has exactly one to offer.
        .onChange(of: homeViewModel.heldShares.isEmpty) { _, isEmpty in
            guard !isEmpty else { return }
            Task { await offerNotifications() }
        }
        // Explained before the system prompt, because on iOS that prompt appears once in an app's
        // lifetime: spending it on a bare dialog leaves somebody who declines with no route back
        // except Settings. Declining here costs nothing — Settings offers it again while iOS has
        // still never been asked.
        .alert("Tell you when somebody is waiting?", isPresented: $showNotificationExplanation) {
            Button("Turn On Notifications") {
                RequestNotifier.markExplanationShown()
                Task { await RequestNotifier.requestAuthorization() }
            }
            Button("Not Now", role: .cancel) {
                RequestNotifier.markExplanationShown()
            }
        } message: {
            Text("You are keeping a share for somebody now. When they need it back, Deposplit can say so — one sentence that names nobody and no secret. Without it, you learn of a request only when you next open the app.")
        }
    }

    private func offerNotifications() async {
        guard !RequestNotifier.explanationShown else { return }
        guard await RequestNotifier.authorizationStatus() == .notDetermined else { return }
        showNotificationExplanation = true
    }

    private func reload() async {
        loadContacts()
        await homeViewModel.load()
        await requestsViewModel.load()
    }

    private func loadContacts() {
        allContacts = (try? contactManagement.listContacts()) ?? []
    }

    private var tabTitle: LocalizedStringKey {
        switch selectedTab {
        case 0: "Split & shared"
        case 1: "Keeping safe"
        default: "Requests"
        }
    }

    private var distributedContent: some View {
        Group {
            if homeViewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = homeViewModel.error {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                DistributedTab(
                    groups: homeViewModel.groupedSecrets,
                    onOpenSecret: { selectedSecret = $0 }
                )
            }
        }
    }

    private var heldContent: some View {
        Group {
            if homeViewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = homeViewModel.error {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                HeldTab(shares: homeViewModel.heldShares, contacts: allContacts)
            }
        }
    }
}

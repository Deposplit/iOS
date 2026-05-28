import hexagon
import SwiftUI

struct HomeView: View {
    private let auth: any Identity
    private let shareManagement: any ShareManagement
    private let contactManagement: any ContactManagement

    @State private var homeViewModel: HomeViewModel
    @State private var requestsViewModel: RequestsViewModel
    @State private var allContacts: [Contact] = []
    @State private var selectedTab = 0
    @State private var showContacts = false
    @State private var showQrDisplay = false
    @State private var showDeposit = false
    @State private var selectedShare: ShareMetadata?

    init(auth: any Identity, shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        self.auth = auth
        self.shareManagement = shareManagement
        self.contactManagement = contactManagement
        _homeViewModel = State(initialValue: HomeViewModel(shareManagement: shareManagement))
        _requestsViewModel = State(initialValue: RequestsViewModel(
            shareManagement: shareManagement,
            contactManagement: contactManagement
        ))
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                Tab("Distributed", systemImage: "arrow.up.circle", value: 0) {
                    distributedContent
                }
                Tab("Held", systemImage: "tray.fill", value: 1) {
                    heldContent
                }
                Tab("Requests", systemImage: "bell", value: 2) {
                    RecipientRequestsTab(viewModel: requestsViewModel)
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
                    }
                }
            }
            .navigationDestination(item: $selectedShare) { share in
                ShareDetailView(share: share, shareManagement: shareManagement, contactManagement: contactManagement)
            }
        }
        .sheet(isPresented: $showContacts, onDismiss: { loadContacts() }) {
            ContactsView(contactManagement: contactManagement)
        }
        .sheet(isPresented: $showQrDisplay) {
            QrDisplayView(auth: auth)
        }
        .sheet(isPresented: $showDeposit, onDismiss: {
            Task { await homeViewModel.load() }
        }) {
            DepositView(shareManagement: shareManagement, contactManagement: contactManagement)
        }
        .task {
            await reload()
        }
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
        case 0: "Distributed"
        case 1: "Held"
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
                    shares: homeViewModel.distributedShares,
                    contacts: allContacts,
                    syncWarning: homeViewModel.syncWarning,
                    onTap: { selectedShare = $0 }
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
                HeldTab(shares: homeViewModel.heldShares, contacts: allContacts, syncWarning: homeViewModel.syncWarning)
            }
        }
    }
}

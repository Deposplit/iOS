import SwiftUI

struct HomeView: View {
    private let auth: AuthPort
    private let transport: ShareTransport
    private let contacts: ContactRepository

    @State private var homeViewModel: HomeViewModel
    @State private var requestsViewModel: RequestsViewModel
    @State private var selectedTab = 0
    @State private var showContacts = false
    @State private var showQrDisplay = false
    @State private var showDeposit = false
    @State private var selectedShare: ShareMetadata?

    init(auth: AuthPort, transport: ShareTransport, contacts: ContactRepository) {
        self.auth = auth
        self.transport = transport
        self.contacts = contacts
        _homeViewModel = State(initialValue: HomeViewModel(transport: transport, auth: auth))
        _requestsViewModel = State(initialValue: RequestsViewModel(transport: transport, contacts: contacts))
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
                                await homeViewModel.load()
                                await requestsViewModel.load()
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .navigationDestination(item: $selectedShare) { share in
                ShareDetailView(share: share, auth: auth, transport: transport, contacts: contacts)
            }
        }
        .sheet(isPresented: $showContacts) {
            ContactsView(repository: contacts)
        }
        .sheet(isPresented: $showQrDisplay) {
            QrDisplayView(auth: auth)
        }
        .sheet(isPresented: $showDeposit, onDismiss: {
            Task { await homeViewModel.load() }
        }) {
            DepositView(auth: auth, transport: transport, contacts: contacts)
        }
        .task {
            await homeViewModel.load()
            await requestsViewModel.load()
        }
    }

    private var tabTitle: String {
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
                    contacts: contacts,
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
                HeldTab(shares: homeViewModel.heldShares, contacts: contacts)
            }
        }
    }
}

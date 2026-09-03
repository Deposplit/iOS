import hexagon
import SwiftUI

struct AddContactView: View {
    @State private var viewModel: AddContactViewModel
    @Environment(\.dismiss) private var dismiss

    private let purchaseStore: StoreKitPurchaseStore

    init(contactManagement: any ContactManagement, purchaseStore: StoreKitPurchaseStore) {
        self.purchaseStore = purchaseStore
        _viewModel = State(initialValue: AddContactViewModel(contactManagement: contactManagement))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Pseudonym", text: $viewModel.pseudonym)
                        .autocorrectionDisabled()
                }
                Section("Verification key (base64url)") {
                    TextField("Verification key", text: $viewModel.verifyKeyInput)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .font(.system(.body, design: .monospaced))
                }
                Section("Encryption key (base64url)") {
                    TextField("Encryption key", text: $viewModel.encKeyInput)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .font(.system(.body, design: .monospaced))
                }
                Section {
                    if purchaseStore.isUnlocked {
                        TextField("https://…", text: $viewModel.relayBaseUrlInput)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        NavigationLink {
                            PaywallView(store: purchaseStore)
                        } label: {
                            Text("See Premium")
                        }
                    }
                } header: {
                    Text("Relay override (optional, BYOR)")
                } footer: {
                    if !purchaseStore.isUnlocked {
                        Text("Naming a contact's relay by hand is part of Premium. A relay carried in a scanned QR code is always free.")
                    }
                }
                Section("Nickname (optional)") {
                    TextField("Nickname", text: $viewModel.nicknameInput)
                        .autocorrectionDisabled()
                }
                Section {
                    ForEach(viewModel.selectableLevels, id: \.self) { level in
                        Button {
                            viewModel.verificationLevel = level
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(level.displayName)
                                        .foregroundStyle(.primary)
                                    Text(level.guidance)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if viewModel.verificationLevel == level {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Verification Level")
                } footer: {
                    Text("How sure are you this is really them? Count your independent assurances: a trusted channel, and/or live proof you saw them.")
                }
                if let error = viewModel.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if viewModel.save() { dismiss() }
                    }
                }
            }
        }
    }
}

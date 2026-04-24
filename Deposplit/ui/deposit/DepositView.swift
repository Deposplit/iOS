import SwiftUI

struct DepositView: View {
    @State private var viewModel: DepositViewModel
    @Environment(\.dismiss) private var dismiss

    init(auth: AuthPort, transport: ShareTransport, contacts: ContactRepository) {
        _viewModel = State(initialValue: DepositViewModel(auth: auth, transport: transport, contacts: contacts))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("e.g. BitLocker recovery key", text: $viewModel.label)
                }

                Section("Secret") {
                    TextEditor(text: $viewModel.secretText)
                        .frame(minHeight: 80)
                        .font(.system(.body, design: .monospaced))
                }

                Section("Recipients") {
                    if viewModel.allContacts.isEmpty {
                        Text("No contacts added yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.allContacts) { contact in
                            Toggle(contact.pseudonym, isOn: Binding(
                                get: { viewModel.selectedContacts.contains(contact.id) },
                                set: { selected in
                                    if selected { viewModel.selectedContacts.insert(contact.id) }
                                    else { viewModel.selectedContacts.remove(contact.id) }
                                }
                            ))
                        }
                    }
                }

                Section {
                    Stepper("Threshold: \(viewModel.threshold) of \(viewModel.selectedContacts.count)",
                            value: $viewModel.threshold,
                            in: 2...max(2, viewModel.selectedContacts.count))
                } footer: {
                    Text("At least \(viewModel.threshold) holder(s) must cooperate to reconstruct the secret.")
                }

                if let error = viewModel.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Split & Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Deposit") {
                        Task { await viewModel.deposit() }
                    }
                    .disabled(!viewModel.canDeposit || viewModel.isDepositing)
                }
            }
            .overlay {
                if viewModel.isDepositing {
                    ProgressView("Depositing…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .onChange(of: viewModel.depositedSuccessfully) { _, success in
                if success { dismiss() }
            }
        }
    }
}

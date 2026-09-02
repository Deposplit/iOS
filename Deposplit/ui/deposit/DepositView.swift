import hexagon
import SwiftUI

struct DepositView: View {
    @State private var viewModel: DepositViewModel
    @Environment(\.dismiss) private var dismiss

    init(shareManagement: any ShareManagement, contactManagement: any ContactManagement) {
        _viewModel = State(initialValue: DepositViewModel(
            shareManagement: shareManagement,
            contactManagement: contactManagement
        ))
    }

    var body: some View {
        NavigationStack {
            DepositFormContent(viewModel: viewModel, title: "Split & Share") {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onChange(of: viewModel.depositedSuccessfully) { _, success in
            if success { dismiss() }
        }
    }
}

/// The deposit form itself, factored out so the Repair flow (`RepairView`) can embed the same
/// validated form — including the split-time warning dialog — inside its own wizard step rather
/// than duplicating it. `DepositView` wraps this in its own `NavigationStack` for the standalone
/// "Split & Share" route; `RepairView` embeds it directly inside its own single `NavigationStack`.
struct DepositFormContent<LeadingToolbar: ToolbarContent>: View {
    @Bindable var viewModel: DepositViewModel
    let title: LocalizedStringKey
    @ToolbarContentBuilder let leadingToolbar: () -> LeadingToolbar

    @State private var showWarningConfirmation = false

    var body: some View {
        Form {
            Section("Label") {
                TextField("e.g. BitLocker recovery key", text: $viewModel.label)
            }

            Section("Secret") {
                if viewModel.isOpaquePayload {
                    // Reconstructed as something other than text, so it is re-split exactly as it
                    // came back rather than edited through a text field.
                    // `verbatim:` because both halves are data, not copy — an interpolated
                    // LocalizedStringKey here would register "%@ · %@" as a translatable string.
                    Label {
                        Text(verbatim: "\(viewModel.mimeType.value) · \(byteCountFormatted(viewModel.secretBytes.count))")
                    } icon: {
                        Image(systemName: "doc")
                    }
                    .font(.system(.body, design: .monospaced))
                    Text("Carried through unchanged — this secret is not text and cannot be edited here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextEditor(text: $viewModel.secretText)
                        .frame(minHeight: 80)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section("Recipients") {
                if viewModel.allContacts.isEmpty {
                    Text("No contacts added yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.allContacts) { contact in
                        Toggle(isOn: Binding(
                            get: { viewModel.selectedContacts.contains(contact.id) },
                            set: { selected in
                                if selected { viewModel.selectedContacts.insert(contact.id) }
                                else { viewModel.selectedContacts.remove(contact.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.displayName)
                                if contact.nickname != nil {
                                    Text(contact.pseudonym).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            leadingToolbar()
            ToolbarItem(placement: .confirmationAction) {
                Button("Deposit") {
                    if viewModel.splitTimeWarnings.isEmpty {
                        Task { await viewModel.deposit() }
                    } else {
                        showWarningConfirmation = true
                    }
                }
                .disabled(!viewModel.canDeposit || viewModel.isDepositing)
            }
        }
        .confirmationDialog("Are you sure?", isPresented: $showWarningConfirmation, titleVisibility: .visible) {
            Button("Deposit Anyway") { Task { await viewModel.deposit() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.splitTimeWarnings.joined(separator: "\n\n"))
        }
        .overlay {
            if viewModel.isDepositing {
                ProgressView("Depositing…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

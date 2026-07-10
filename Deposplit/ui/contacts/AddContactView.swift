import hexagon
import SwiftUI

struct AddContactView: View {
    @State private var viewModel: AddContactViewModel
    @Environment(\.dismiss) private var dismiss

    init(contactManagement: any ContactManagement) {
        _viewModel = State(initialValue: AddContactViewModel(contactManagement: contactManagement))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Pseudonym", text: $viewModel.pseudonym)
                        .autocorrectionDisabled()
                }
                Section("Ed25519 public key (base64url)") {
                    TextField("Ed25519 key", text: $viewModel.edKeyInput)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .font(.system(.body, design: .monospaced))
                }
                Section("X25519 public key (base64url)") {
                    TextField("X25519 key", text: $viewModel.xKeyInput)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .font(.system(.body, design: .monospaced))
                }
                Section("Relay override (optional, BYOR)") {
                    TextField("https://…", text: $viewModel.relayBaseUrlInput)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .font(.system(.body, design: .monospaced))
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

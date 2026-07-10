import hexagon
import SwiftUI

struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    init(relaySettings: any RelaySettings) {
        _viewModel = State(initialValue: SettingsViewModel(relaySettings: relaySettings))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $viewModel.relayBaseUrl)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Default relay")
                } footer: {
                    Text("Used for contacts without a BYOR override, and advertised in your own QR code.")
                }
                Section {
                    Button("Reset to Default", role: .destructive) {
                        viewModel.resetToDefault()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        viewModel.save()
                        dismiss()
                    }
                }
            }
        }
    }
}

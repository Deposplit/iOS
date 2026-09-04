import hexagon
import SwiftUI

/// Shown instead of Home when this device's private keys did not survive a phone switch. Blocking,
/// because every signed action would fail anyway — and because the one thing that must not happen
/// is the user handing out a QR code for an identity they can no longer prove.
struct KeysLostView: View {
    @State private var viewModel: KeysLostViewModel
    var onNewKeys: () -> Void

    init(auth: Identity, onNewKeys: @escaping () -> Void) {
        _viewModel = State(initialValue: KeysLostViewModel(auth: auth))
        self.onNewKeys = onNewKeys
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This phone restored everything except your keys. They were held by your old phone in a way that cannot be copied, so this device can no longer sign or decrypt as you.")
                    Text("Nothing else was lost. The secrets you split are still recoverable, and the shares you keep for other people are still here.")
                }

                Section {
                    TextField("Your pseudonym", text: $viewModel.pseudonym)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Create new keys, then meet your contacts and let them scan your new code — both the people holding shares for you and the people whose shares you hold. Until they do, they cannot reach you.")
                }

                if let error = viewModel.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        viewModel.createNewKeys()
                        if viewModel.error == nil && !viewModel.isLoading {
                            onNewKeys()
                        }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Text("Create new keys")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(viewModel.pseudonym.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isLoading)
                }
            }
            .navigationTitle("Your keys did not come across")
        }
    }
}

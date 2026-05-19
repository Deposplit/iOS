import hexagon
import SwiftUI

struct SignInView: View {
    @State private var viewModel: SignInViewModel
    var onRegistered: () -> Void

    init(auth: Identity, onRegistered: @escaping () -> Void) {
        _viewModel = State(initialValue: SignInViewModel(auth: auth))
        self.onRegistered = onRegistered
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $viewModel.pseudonym)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                } header: {
                    Text("Choose a name")
                } footer: {
                    Text("This name is stored only on your device and shared with contacts when they scan your QR code.")
                }

                if let error = viewModel.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        viewModel.register()
                        if viewModel.error == nil && !viewModel.isLoading {
                            onRegistered()
                        }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Text("Get started")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(viewModel.pseudonym.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isLoading)
                }
            }
            .navigationTitle("Deposplit")
        }
    }
}

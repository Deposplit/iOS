import SwiftUI

struct QrDisplayView: View {
    @State private var viewModel: QrDisplayViewModel
    @Environment(\.dismiss) private var dismiss

    init(auth: AuthPort) {
        _viewModel = State(initialValue: QrDisplayViewModel(auth: auth))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let image = viewModel.qrImage {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 300, maxHeight: 300)
                        .padding()
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 4)
                } else {
                    ProgressView()
                        .frame(width: 300, height: 300)
                }
                if !viewModel.pseudonym.isEmpty {
                    Text(viewModel.pseudonym).font(.title2.weight(.semibold))
                }
                Text("Let contacts scan this code to add you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .navigationTitle("My QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { viewModel.generate() }
        }
    }
}

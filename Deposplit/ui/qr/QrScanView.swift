import hexagon
import SwiftUI
import Vision
import VisionKit

struct QrScanView: View {
    @State private var viewModel: QrScanViewModel
    @Environment(\.dismiss) private var dismiss

    init(repository: ContactRepository) {
        _viewModel = State(initialValue: QrScanViewModel(repository: repository))
    }

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    DataScannerRepresentable(
                        onScan: { string in
                            if !viewModel.hasScanned {
                                viewModel.handleScan(string)
                            }
                        }
                    )
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        if let error = viewModel.error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(.red, in: RoundedRectangle(cornerRadius: 8))
                                .padding()
                        }
                    }
                } else {
                    ContentUnavailableView("Camera unavailable",
                                          systemImage: "camera.slash",
                                          description: Text("Camera access is required to scan QR codes."))
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: viewModel.savedContact) { _, contact in
                if contact != nil { dismiss() }
            }
        }
    }
}

@Observable
final class QrScanViewModel {
    var hasScanned = false
    var error: String?
    var savedContact: Contact?

    private let repository: ContactRepository

    init(repository: ContactRepository) {
        self.repository = repository
    }

    func handleScan(_ string: String) {
        guard !hasScanned else { return }
        guard let payload = QrPayload.decode(string), payload.v == 1 else {
            error = String(localized: "Not a valid Deposplit QR code.")
            return
        }
        let vm = AddContactViewModel(repository: repository)
        if vm.saveFromQR(payload: payload) {
            hasScanned = true
            savedContact = repository.getByEdKey(Data(base64URLEncoded: payload.ed) ?? Data())
        } else {
            error = vm.error
        }
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case let .barcode(barcode) = item, let string = barcode.payloadStringValue {
                    onScan(string)
                }
            }
        }
    }
}

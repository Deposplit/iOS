import hexagon
import SwiftUI
import Vision
import VisionKit

struct QrScanView: View {
    @State private var viewModel: QrScanViewModel
    @Environment(\.dismiss) private var dismiss

    init(contactManagement: any ContactManagement) {
        _viewModel = State(initialValue: QrScanViewModel(contactManagement: contactManagement))
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
            .onChange(of: viewModel.didSave) { _, saved in
                if saved { dismiss() }
            }
        }
    }
}

@Observable
final class QrScanViewModel {
    var hasScanned = false
    var error: String?
    var didSave = false

    private let contactManagement: any ContactManagement

    init(contactManagement: any ContactManagement) {
        self.contactManagement = contactManagement
    }

    func handleScan(_ string: String) {
        guard !hasScanned else { return }
        guard let payload = QrPayload.decode(string), (1...2).contains(payload.v) else {
            error = String(localized: "Not a valid Deposplit QR code.")
            return
        }
        guard let ed = Data(base64URLEncoded: payload.ed), let x = Data(base64URLEncoded: payload.x) else {
            error = String(localized: "Invalid keys in QR payload.")
            return
        }
        do {
            // A QR scan defaults to in-person co-presence, the strongest assurance the current
            // scan flow can claim (CLAUDE.md item 6). A remote/video-call scan is a weaker claim,
            // but there's no UI step here to downgrade it yet — the user can always edit the
            // contact's level later once item 6's on-device editing UI exists.
            try contactManagement.addFromQr(pseudonym: payload.pseudonym, edPublicKey: ed, xPublicKey: x, verificationLevel: .veryHigh, relayBaseUrl: payload.relay)
            hasScanned = true
            didSave = true
        } catch {
            self.error = error.localizedDescription
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

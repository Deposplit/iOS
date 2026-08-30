import hexagon
import SwiftUI
import VisionKit

/// Holder-side "this contact's key changed" flow, used to relink a re-presented identity.
/// Scans the contact's re-presented QR code, updates the existing contact record **in place**
/// (preserving `contactId` — see `ContactManagement.updateContact`), then pushes a metadata-only
/// recovery report for every share held from them, so a recovering owner on a fresh device can
/// rebuild her records. Distinct from `QrScanView` (which always creates a *new* contact) —
/// mixing the two up would mint a fresh `contactId` and orphan the held shares.
struct RelinkContactView: View {
    @State private var viewModel: RelinkContactViewModel
    @Environment(\.dismiss) private var dismiss

    init(contact: Contact, contactManagement: any ContactManagement, shareManagement: any ShareManagement) {
        _viewModel = State(initialValue: RelinkContactViewModel(contact: contact, contactManagement: contactManagement, shareManagement: shareManagement))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let level = viewModel.pendingLevel {
                    Form {
                        Section {
                            Text("Scanned new keys for **\(viewModel.contact.displayName)**.")
                        } header: {
                            Text("New keys")
                        } footer: {
                            Text("A key change always requires re-choosing a verification level fresh — it can never inherit the old one.")
                        }
                        Picker("Verification level", selection: Binding(
                            get: { level },
                            set: { viewModel.pendingLevel = $0 }
                        )) {
                            ForEach(VerificationLevel.allCases, id: \.self) { l in
                                Text(l.displayName).tag(l)
                            }
                        }
                        if let error = viewModel.error {
                            Text(error).foregroundStyle(.red).font(.caption)
                        }
                        Button("Confirm Relink") {
                            Task { await viewModel.confirm() }
                        }
                    }
                } else if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
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
            .navigationTitle("Relink \(viewModel.contact.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: viewModel.didFinish) { _, finished in
                if finished { dismiss() }
            }
        }
    }
}

@Observable
final class RelinkContactViewModel {
    let contact: Contact
    var hasScanned = false
    var error: String?
    var didFinish = false
    var pendingLevel: VerificationLevel?

    private var pendingVerifyKey: Data?
    private var pendingEncKey: Data?
    private var pendingCipherSuite: CipherSuite?
    private let contactManagement: any ContactManagement
    private let shareManagement: any ShareManagement

    init(contact: Contact, contactManagement: any ContactManagement, shareManagement: any ShareManagement) {
        self.contact = contact
        self.contactManagement = contactManagement
        self.shareManagement = shareManagement
    }

    func handleScan(_ string: String) {
        guard !hasScanned else { return }
        // No version gate: `v` stays at 1 permanently (pre-launch, never decodes an old shape —
        // see QrPayload.swift). A payload missing a required field like cipherSuite
        // already fails to decode on its own; checking `v` would add nothing.
        guard let payload = QrPayload.decode(string) else {
            error = String(localized: "Not a valid Deposplit QR code.")
            return
        }
        guard let verifyKey = Data(base64URLEncoded: payload.verifyKey), let encKey = Data(base64URLEncoded: payload.encKey) else {
            error = String(localized: "Invalid keys in QR payload.")
            return
        }
        guard let cipherSuite = CipherSuite(rawValue: payload.cipherSuite) else {
            error = String(localized: "This QR code uses an encryption scheme this app version doesn't support.")
            return
        }
        hasScanned = true
        pendingVerifyKey = verifyKey
        pendingEncKey = encKey
        pendingCipherSuite = cipherSuite
        // In-person re-scan is the strongest assurance this flow can claim — defaulted, but
        // always shown for confirmation since a key change forces a fresh choice.
        pendingLevel = .veryHigh
    }

    func confirm() async {
        guard let verifyKey = pendingVerifyKey, let encKey = pendingEncKey, let cipherSuite = pendingCipherSuite, let level = pendingLevel else { return }
        do {
            try contactManagement.updateContact(contactId: contact.id, verifyKey: verifyKey, encKey: encKey, newCipherSuite: cipherSuite, verificationLevel: level)
            try await shareManagement.pushRecoveryMetadata(contactId: contact.id)
            didFinish = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

import hexagon
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false

    var body: some View {
        Form {
            Section("Label") {
                TextField("e.g. BitLocker recovery key", text: $viewModel.label)
            }

            Section("Secret") {
                if viewModel.isOpaquePayload {
                    // Bytes rather than editable text — a picked image, or something a repair
                    // carried back. Either way it is split exactly as it stands: re-encoding it
                    // through a text field is what used to corrupt a non-text secret.
                    if case .image(let image, _) = ReconstructedSecret(secret: viewModel.secretBytes, mimeType: viewModel.mimeType) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 160)
                            .accessibilityLabel("Selected image")
                    }
                    // `verbatim:` because both halves are data, not copy — an interpolated
                    // LocalizedStringKey here would register "%@ · %@" as a translatable string.
                    Label {
                        Text(verbatim: "\(viewModel.mimeType.value) · \(byteCountFormatted(viewModel.secretBytes.count))")
                    } icon: {
                        Image(systemName: "doc")
                    }
                    .font(.system(.body, design: .monospaced))
                    if viewModel.isCarriedThrough {
                        Text("Carried through unchanged — this secret is not text and cannot be edited here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Remove", systemImage: "xmark.circle", role: .destructive) {
                        viewModel.clearPickedFile()
                    }
                    .font(.caption)
                } else {
                    TextEditor(text: $viewModel.secretText)
                        .frame(minHeight: 80)
                        .font(.system(.body, design: .monospaced))
                    // Photos and Files are separate sources on iOS — Files cannot see the photo
                    // library — so covering both takes both pickers.
                    PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                        Label("Choose Photo…", systemImage: "photo")
                    }
                    .font(.caption)
                    Button("Choose File…", systemImage: "folder") { showFileImporter = true }
                        .font(.caption)
                }
                if let pickError = viewModel.pickError {
                    // Already localised by the view model, which is where the byte counts are
                    // formatted — so this is deliberately the plain-String overload, not a
                    // LocalizedStringKey lookup that would go looking for the finished sentence.
                    Text(verbatim: pickError)
                        .font(.caption)
                        .foregroundStyle(.red)
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
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                // `Data.self` hands back the asset's own representation. Asking for a transcode
                // instead would re-encode the secret behind the user's back, which is exactly what
                // "split it verbatim or refuse it" rules out — a HEIC photo is refused by type.
                if let data = try? await item.loadTransferable(type: Data.self) {
                    viewModel.usePickedFile(data)
                }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.png, .jpeg]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            // Mapped rather than read: `count` is then the file's real size without pulling an
            // arbitrarily large file into memory just to discover it is too big.
            if let mapped = try? Data(contentsOf: url, options: .mappedIfSafe) {
                viewModel.usePickedFile(mapped)
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

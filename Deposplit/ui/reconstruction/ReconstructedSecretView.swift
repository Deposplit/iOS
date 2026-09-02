import SwiftUI
import UniformTypeIdentifiers
import hexagon

/// Renders whatever `reconstruct` produced, forking on `ReconstructedSecret`. Shown wherever a
/// reconstructed secret is displayed, alongside `ReconstructionAdvisoryView`.
///
/// The export writes the reconstructed **plaintext** to a temporary file and hands it to
/// `ShareLink`. That is a real confidentiality surface — unlike the catalogue backup, which
/// carries no shares and no keys — so it is offered per reconstruction, at the user's request,
/// and never written anywhere on its own initiative.
struct ReconstructedSecretView: View {
    let secret: ReconstructedSecret
    let mimeType: MimeType
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch secret {
            case .text(let text):
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = text
                }
                .font(.caption)

            case .image(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .accessibilityLabel("Reconstructed image")
                exportLink(data: image.pngData() ?? Data())

            case .binary(let data):
                // `verbatim:` because both halves are data, not copy — an interpolated
                // LocalizedStringKey here would register "%@ · %@" as a translatable string.
                Label {
                    Text(verbatim: "\(mimeType.value) · \(byteCountFormatted(data.count))")
                } icon: {
                    Image(systemName: "doc")
                }
                .font(.system(.body, design: .monospaced))
                Text("This secret is not text that can be shown here. Export it to open it elsewhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                exportLink(data: data)
            }
        }
    }

    @ViewBuilder
    private func exportLink(data: Data) -> some View {
        if let url = try? writeToTemporaryFile(data) {
            ShareLink(item: url) {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .font(.caption)
        }
    }

    /// Named from the label and the declared type, so the exported file arrives somewhere useful
    /// with an extension its destination understands. An unrecognised type simply gets none.
    private func writeToTemporaryFile(_ data: Data) throws -> URL {
        let base = label.trimmingCharacters(in: .whitespaces).isEmpty ? "secret" : label
        let safeBase = base.replacingOccurrences(of: "/", with: "-")
        let ext = UTType(mimeType: mimeType.value)?.preferredFilenameExtension
        var name = safeBase
        if let ext { name += ".\(ext)" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}

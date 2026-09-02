import Foundation
import UIKit
import hexagon

/// How a reconstructed secret should be shown, decided once from the declared type *and* the bytes
/// themselves so every reconstruct site agrees and none has to re-derive it.
///
/// The classification is deliberately fail-safe. A declared type is only ever a claim — nothing
/// verified it against the payload, and nothing could, since the relay only ever saw ciphertext —
/// so every branch that could fail falls through to `.binary` rather than erroring or guessing.
/// That is also why a `text/*` payload is checked for valid UTF-8 instead of being force-decoded:
/// the lossy decode it replaces silently substituted U+FFFD and threw the real bytes away.
///
/// A wrong or hostile type is therefore a rendering matter, never a confidentiality one. By the
/// time it is read, `k` holders have already consented and the plaintext is already here.
enum ReconstructedSecret {
    case text(String)
    /// Carries the payload beside the decoded image, because the decoded image is *not* the secret:
    /// re-encoding it would hand back different bytes under the original type's name. Export uses
    /// `original`; only the display uses the `UIImage`.
    case image(UIImage, original: Data)
    case binary(Data)

    init(secret: Data, mimeType: MimeType) {
        if mimeType.isText, let text = String(data: secret, encoding: .utf8) {
            self = .text(text)
        } else if mimeType.isImage, let image = UIImage(data: secret) {
            // `UIImage(data:)` is the platform's own sandboxed decoder, and returns nil rather than
            // throwing on malformed input — which is the fall-through this relies on. No image
            // library is bundled, deliberately: attacker-chosen bytes reaching a decoder is the one
            // real risk a bad mimeType creates.
            self = .image(image, original: secret)
        } else {
            self = .binary(secret)
        }
    }
}

/// Human-readable byte count, for the binary view and the repair form's carried-through payload.
func byteCountFormatted(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}

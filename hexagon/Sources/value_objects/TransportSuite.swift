import Foundation

/// The KDF + AEAD construction a ciphertext blob was sealed with — a lightweight, per-message tag
/// distinct from `CipherSuite`. Only the KDF/AEAD
/// pair needs an in-band tag: the key-agreement algorithm is already unambiguous by the time
/// encryption starts (the sender can't perform key agreement without first knowing the
/// recipient's `CipherSuite`, and the recipient already knows its own current keypair's
/// algorithm), so only "which KDF/AEAD did the sender's software happen to apply" is genuinely
/// new information. Needs no persistent state or trust mechanism at all — each deposit and
/// retrieval leg is re-derived fresh, so a device just always encrypts with its current
/// preferred suite and a decrypting device dispatches on the tag it reads.
public enum TransportSuite: UInt8, Sendable {
    /// X25519 key agreement -> HKDF-SHA-256 -> ChaCha20-Poly1305. The only construction that
    /// exists today.
    case x25519HkdfSha256ChaCha20Poly1305 = 0x01

    /// The construction this codebase's `ShareEncryption` currently applies.
    public static let current: TransportSuite = .x25519HkdfSha256ChaCha20Poly1305
}

/// Thrown by `ShareEncryption.decrypt` on a ciphertext blob whose leading suite tag this app
/// version doesn't recognize — never a silent misparse.
public enum TransportSuiteError: Error, LocalizedError {
    case unsupported(tag: UInt8)

    public var errorDescription: String? {
        switch self {
        case .unsupported: "This share used an encryption scheme this app version doesn't support."
        }
    }
}

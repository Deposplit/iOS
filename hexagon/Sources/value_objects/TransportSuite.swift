import Foundation

/// The construction a box was sealed with — a lightweight, per-message tag distinct from
/// `CipherSuite`, which names the key types. Those are unambiguous by the time a box is sealed (the
/// sender seals to the recipient's advertised key, and the recipient knows its own), so only "which
/// construction did the sender's software apply" is genuinely new information. Needs no persistent
/// state or trust mechanism at all — each box is sealed fresh, so a device just always seals with
/// its current preferred suite and an opening device dispatches on the tag it reads.
public enum TransportSuite: UInt8, Sendable {
    /// HPKE base mode (RFC 9180): DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305,
    /// with a fresh ephemeral sender key per box. The only construction that exists today. Tag
    /// 0x01 was a static-static box the sender could reopen, and is gone rather than kept
    /// readable, so a leftover box from it fails loudly instead of misparsing.
    case hpkeX25519Sha256ChaCha20Poly1305 = 0x02

    /// The construction this codebase's `ShareEncryption` currently applies.
    public static let current: TransportSuite = .hpkeX25519Sha256ChaCha20Poly1305
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

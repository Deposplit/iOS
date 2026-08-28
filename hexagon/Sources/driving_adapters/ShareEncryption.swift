import Foundation

/// Intra-hexagon interface — implemented by `IdentityService`, consumed by `ShareService`.
/// Lives in `services/` rather than `driving_ports` or `driven_ports` because both its
/// implementer and consumer are within the hexagon's service layer.
public protocol ShareEncryption {
    /// Encrypts `plaintext` to `recipientEncKey` via the current `TransportSuite` (today:
    /// X25519+HKDF-SHA-256+ChaCha20-Poly1305). Returns suiteTag(1) || nonce(12) || ciphertext+tag
    /// — item 14's per-message transport tag rides for free inside this already-opaque blob.
    func encrypt(_ plaintext: Data, recipientEncKey: Data) throws -> Data
    /// Decrypts `data` (suiteTag(1) || nonce(12) || ciphertext+tag) using `recipientEncKey`,
    /// dispatching on the leading `TransportSuite` tag. Throws `TransportSuiteError.unsupported`
    /// for an unrecognized tag — never a silent misparse.
    func decrypt(_ data: Data, recipientEncKey: Data) throws -> Data
}

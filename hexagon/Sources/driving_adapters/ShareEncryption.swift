import Foundation

/// Intra-hexagon interface — implemented by `IdentityService`, consumed by `ShareService`.
/// Lives in `services/` rather than `driving_ports` or `driven_ports` because both its
/// implementer and consumer are within the hexagon's service layer.
public protocol ShareEncryption {
    /// Encrypts `plaintext` to `recipientEncKey` via the current `TransportSuite` (today:
    /// X25519+HKDF-SHA-256+ChaCha20-Poly1305). Returns suiteTag(1) || nonce(12) || ciphertext+tag
    /// — the per-message transport-suite tag rides for free inside this already-opaque blob.
    func encrypt(_ plaintext: Data, recipientEncKey: Data) throws -> Data
    /// Decrypts `data` (suiteTag(1) || nonce(12) || ciphertext+tag) using `recipientEncKey`,
    /// dispatching on the leading `TransportSuite` tag. Throws `TransportSuiteError.unsupported`
    /// for an unrecognized tag — never a silent misparse.
    func decrypt(_ data: Data, recipientEncKey: Data) throws -> Data
    /// Seals a secret's label to `recipientEncKey` with the same box as `encrypt`, under a key
    /// derivation of its own, so a label box and a share box never share a derived key. The relay
    /// stores the result without being able to read it.
    func sealLabel(_ label: String, recipientEncKey: Data) throws -> Data
    /// Opens a label sealed by `sealLabel` under the row sender's `senderEncKey`, with the same
    /// fallback to the previous `decKey` as `decrypt`.
    func openLabel(_ sealedLabel: Data, senderEncKey: Data) throws -> String
}

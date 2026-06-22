import Foundation

/// Intra-hexagon interface — implemented by `IdentityService`, consumed by `ShareService`.
/// Lives in `services/` rather than `driving_ports` or `driven_ports` because both its
/// implementer and consumer are within the hexagon's service layer.
public protocol ShareEncryption {
    /// Encrypts `plaintext` to `recipientXPublicKey` via X25519+HKDF-SHA-256+ChaCha20-Poly1305.
    /// Returns nonce(12) || ciphertext+tag.
    func encrypt(_ plaintext: Data, recipientXPublicKey: Data) throws -> Data
    /// Decrypts `noncePlusCiphertext` (nonce(12) || ciphertext+tag) using `recipientXPublicKey`.
    func decrypt(_ noncePlusCiphertext: Data, recipientXPublicKey: Data) throws -> Data
}

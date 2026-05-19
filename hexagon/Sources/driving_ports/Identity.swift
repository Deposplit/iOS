import Foundation

public protocol Identity {
    var isRegistered: Bool { get }
    func register(pseudonym: String) throws
    var pseudonym: String { get }
    /// Ed25519 public key — 32 raw bytes
    var edPublicKey: Data { get }
    /// X25519 public key — 32 raw bytes
    var xPublicKey: Data { get }
    /// Signs `message` with the Ed25519 private key. Returns the 64-byte signature.
    func sign(_ message: Data) throws -> Data
    /// Encrypts `plaintext` to `recipientXPublicKey` via X25519+HKDF-SHA-256+ChaCha20-Poly1305.
    /// Returns nonce(12) || ciphertext+tag.
    func encrypt(_ plaintext: Data, recipientXPublicKey: Data) throws -> Data
    /// Decrypts `noncePlusCiphertext` (nonce(12) || ciphertext+tag) using `recipientXPublicKey`.
    func decrypt(_ noncePlusCiphertext: Data, recipientXPublicKey: Data) throws -> Data
}

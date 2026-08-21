import Foundation

public protocol Identity {
    var isRegistered: Bool { get }
    func register(pseudonym: String) throws
    var pseudonym: String { get }
    /// Ed25519 public key — 32 raw bytes
    var verifyKey: Data { get }
    /// X25519 public key — 32 raw bytes
    var encKey: Data { get }
    /// Signs `message` with the Ed25519 private key. Returns the 64-byte signature.
    func sign(_ message: Data) throws -> Data

    /// Verifies an Ed25519 `signature` over `message` against `publicKey` (someone else's, not
    /// this identity's own). Used to independently re-verify the senderSignature/
    /// recipientSignature that ride with a ShareRequest row — see `PayloadCanonical`.
    func verify(_ message: Data, signature: Data, publicKey: Data) -> Bool

    /// Item 9 — generates a fresh Ed25519 + X25519 keypair without touching storage. The caller
    /// (see `ShareManagement.regenerateIdentity`) is expected to push a rotation notice signed by
    /// the *current* (soon-to-be-old) identity before calling `activateKeyPair`, proving
    /// continuity of key control to every contact.
    func generateNewKeyPair() -> KeyPairMaterial

    /// Item 9 — persists `keyPair` as this device's identity, preserving the existing pseudonym.
    /// After this call, `sign`/`verifyKey`/`encKey` all reflect the new keys.
    func activateKeyPair(_ keyPair: KeyPairMaterial) throws
}

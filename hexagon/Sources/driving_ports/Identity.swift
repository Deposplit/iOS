import Foundation

public protocol Identity {
    var isRegistered: Bool { get }

    /// Whether the private keys this device believes it has are still there and still match the
    /// public keys it advertises. Total and non-throwing: a device that cannot answer the question
    /// reports `.unreadable` rather than failing, and an unregistered device reports `.intact`
    /// because it has nothing to have lost.
    var integrity: IdentityIntegrity { get }
    func register(pseudonym: String) throws
    var pseudonym: String { get }
    /// When the identity this device holds today was established. Moves on registration and stays
    /// put across a rotation — see `IdentityStore.identityCreatedAt`. Nil on a device registered
    /// before this was recorded.
    var identityCreatedAt: Date? { get }
    /// Ed25519 public key — 32 raw bytes, or nil when this device's keys are gone or cannot be
    /// read. An ordinary state on a phone restored from a backup, whose files came across without
    /// the keys, so optional rather than throwing — the same reasoning as `previousDecKey()`.
    /// Callers wanting the fuller answer, gone versus merely locked, ask `integrity`.
    var verifyKey: Data? { get }
    /// X25519 public key — 32 raw bytes, or nil. See `verifyKey`.
    var encKey: Data? { get }
    /// Signs `message` with the Ed25519 private key. Returns the 64-byte signature.
    func sign(_ message: Data) throws -> Data

    /// Verifies an Ed25519 `signature` over `message` against `publicKey` (someone else's, not
    /// this identity's own). Used to independently re-verify the senderSignature/
    /// recipientSignature that ride with a ShareRequest row — see `PayloadCanonical`.
    func verify(_ message: Data, signature: Data, publicKey: Data) -> Bool

    /// Generates a fresh Ed25519 + X25519 keypair without touching storage. The caller
    /// (see `ShareManagement.regenerateIdentity`) is expected to push a rotation notice signed by
    /// the *current* (soon-to-be-old) identity before calling `activateKeyPair`, proving
    /// continuity of key control to every contact.
    func generateNewKeyPair() -> KeyPairMaterial

    /// Persists `keyPair` as this device's identity, preserving the existing pseudonym.
    /// After this call, `sign`/`verifyKey`/`encKey` all reflect the new keys.
    ///
    /// The displaced `decKey` is kept one generation deep, so a share sealed to the old `encKey`
    /// while it was still current can still be opened at pickup. The displaced `signKey` is not:
    /// this device stops being able to sign as its former self the moment it rotates.
    func activateKeyPair(_ keyPair: KeyPairMaterial) throws
}

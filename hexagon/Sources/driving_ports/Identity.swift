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

    /// Verifies an Ed25519 `signature` over `message` against `publicKey` (someone else's, not
    /// this identity's own). Used to independently re-verify the senderSignature/
    /// recipientSignature that ride with a ShareRequest row — see `PayloadCanonical`.
    func verify(_ message: Data, signature: Data, publicKey: Data) -> Bool
}

import Foundation

public protocol Identity {
    var isRegistered: Bool { get }
    func register(pseudonym: String) throws
    var pseudonym: String { get }
    /// Ed25519 public key — 32 raw bytes
    var edPublicKey: Data { get }
    /// X25519 public key — 32 raw bytes
    var xPublicKey: Data { get }
}

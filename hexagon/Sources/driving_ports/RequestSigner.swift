import Foundation

/// Driving port: defined by the hexagon, implemented by `IdentityService`, consumed by
/// `DeposplitApiAdapter` to authenticate outbound API requests.
public protocol RequestSigner {
    /// Ed25519 public key — 32 raw bytes
    var edPublicKey: Data { get }
    /// Signs `message` with the Ed25519 private key. Returns the 64-byte signature.
    func sign(_ message: Data) throws -> Data
}

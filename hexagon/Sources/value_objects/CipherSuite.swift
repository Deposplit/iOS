import Foundation

/// The matched pairing of signing algorithm + key-agreement algorithm an identity currently uses
/// — the crypto-agility mechanism. One case exists today;
/// the point of naming it explicitly is making a future fleet-wide algorithm swap an additive new
/// case rather than a breaking wire-format migration. Bundled as one value (not two independent
/// per-algorithm tags) because both of a device's keypairs are generated together and rotate
/// together — nothing today expresses "signing algorithm A with agreement algorithm B" as a valid
/// combination distinct from this one.
public enum CipherSuite: String, Codable, Sendable, CaseIterable, Hashable {
    case ed25519X25519V1 = "ed25519+x25519-v1"

    /// The only suite this codebase's key generation can produce today.
    public static let current: CipherSuite = .ed25519X25519V1

    /// The signing-key length this suite implies, in bytes.
    public var verifyKeyLength: Int {
        switch self {
        case .ed25519X25519V1: 32
        }
    }

    /// The key-agreement key length this suite implies, in bytes.
    public var encKeyLength: Int {
        switch self {
        case .ed25519X25519V1: 32
        }
    }
}

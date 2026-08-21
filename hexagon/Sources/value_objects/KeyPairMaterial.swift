import Foundation

/// A freshly generated Ed25519 + X25519 keypair, not yet persisted as this device's identity —
/// see item 9's "regenerate my own identity" trigger. Kept separate from `IdentityStore.save`'s
/// parameters so a caller can push a signed rotation notice (proving continuity from the *old*
/// key) before activating the new one.
public struct KeyPairMaterial: Equatable {
    public let edPublicKey: Data
    public let edPrivateKey: Data
    public let xPublicKey: Data
    public let xPrivateKey: Data

    public init(edPublicKey: Data, edPrivateKey: Data, xPublicKey: Data, xPrivateKey: Data) {
        self.edPublicKey = edPublicKey
        self.edPrivateKey = edPrivateKey
        self.xPublicKey = xPublicKey
        self.xPrivateKey = xPrivateKey
    }
}

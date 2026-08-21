import Foundation

/// A freshly generated Ed25519 + X25519 keypair, not yet persisted as this device's identity —
/// see item 9's "regenerate my own identity" trigger. Kept separate from `IdentityStore.save`'s
/// parameters so a caller can push a signed rotation notice (proving continuity from the *old*
/// key) before activating the new one.
public struct KeyPairMaterial: Equatable {
    public let verifyKey: Data
    public let signKey: Data
    public let encKey: Data
    public let decKey: Data

    public init(verifyKey: Data, signKey: Data, encKey: Data, decKey: Data) {
        self.verifyKey = verifyKey
        self.signKey = signKey
        self.encKey = encKey
        self.decKey = decKey
    }
}

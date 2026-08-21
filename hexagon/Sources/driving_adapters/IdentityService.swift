import CryptoKit
import Foundation

public final class IdentityService: Identity, ShareEncryption {
    private let identityStore: any IdentityStore

    public init(identityStore: any IdentityStore) {
        self.identityStore = identityStore
    }

    public var isRegistered: Bool { identityStore.isRegistered }
    public var pseudonym: String { identityStore.pseudonym }
    public var edPublicKey: Data { identityStore.edPublicKey }
    public var xPublicKey: Data { identityStore.xPublicKey }

    public func register(pseudonym: String) throws {
        let material = Self.generateKeyPairMaterial()
        try identityStore.save(
            pseudonym: pseudonym,
            edPk: material.edPublicKey,
            edSk: material.edPrivateKey,
            xPk: material.xPublicKey,
            xSk: material.xPrivateKey
        )
    }

    public func generateNewKeyPair() -> KeyPairMaterial {
        Self.generateKeyPairMaterial()
    }

    public func activateKeyPair(_ keyPair: KeyPairMaterial) throws {
        try identityStore.save(
            pseudonym: identityStore.pseudonym,
            edPk: keyPair.edPublicKey,
            edSk: keyPair.edPrivateKey,
            xPk: keyPair.xPublicKey,
            xSk: keyPair.xPrivateKey
        )
    }

    private static func generateKeyPairMaterial() -> KeyPairMaterial {
        let edKey = Curve25519.Signing.PrivateKey()
        let xKey = Curve25519.KeyAgreement.PrivateKey()
        return KeyPairMaterial(
            edPublicKey: edKey.publicKey.rawRepresentation,
            edPrivateKey: edKey.rawRepresentation,
            xPublicKey: xKey.publicKey.rawRepresentation,
            xPrivateKey: xKey.rawRepresentation
        )
    }

    public func sign(_ message: Data) throws -> Data {
        let rawKey = try identityStore.edPrivateKey()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
        return try key.signature(for: message)
    }

    public func verify(_ message: Data, signature: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    public func encrypt(_ plaintext: Data, recipientXPublicKey: Data) throws -> Data {
        let rawKey = try identityStore.xPrivateKey()
        let myKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawKey)
        let theirKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientXPublicKey)
        let sharedSecret = try myKey.sharedSecretFromKeyAgreement(with: theirKey)

        let nonce = ChaChaPoly.Nonce()
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(nonce),
            sharedInfo: Data("deposplit-share".utf8),
            outputByteCount: 32
        )
        let sealedBox = try ChaChaPoly.seal(plaintext, using: symmetricKey, nonce: nonce)
        return sealedBox.combined
    }

    public func decrypt(_ noncePlusCiphertext: Data, recipientXPublicKey: Data) throws -> Data {
        let rawKey = try identityStore.xPrivateKey()
        let myKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawKey)
        let theirKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientXPublicKey)
        let sharedSecret = try myKey.sharedSecretFromKeyAgreement(with: theirKey)

        let sealedBox = try ChaChaPoly.SealedBox(combined: noncePlusCiphertext)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(sealedBox.nonce),
            sharedInfo: Data("deposplit-share".utf8),
            outputByteCount: 32
        )
        return try ChaChaPoly.open(sealedBox, using: symmetricKey)
    }
}

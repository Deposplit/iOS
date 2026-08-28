import CryptoKit
import Foundation

public final class IdentityService: Identity, ShareEncryption {
    private let identityStore: any IdentityStore

    public init(identityStore: any IdentityStore) {
        self.identityStore = identityStore
    }

    public var isRegistered: Bool { identityStore.isRegistered }
    public var pseudonym: String { identityStore.pseudonym }
    public var verifyKey: Data { identityStore.verifyKey }
    public var encKey: Data { identityStore.encKey }

    public func register(pseudonym: String) throws {
        let material = Self.generateKeyPairMaterial()
        try identityStore.save(
            pseudonym: pseudonym,
            verifyKey: material.verifyKey,
            signKey: material.signKey,
            encKey: material.encKey,
            decKey: material.decKey
        )
    }

    public func generateNewKeyPair() -> KeyPairMaterial {
        Self.generateKeyPairMaterial()
    }

    public func activateKeyPair(_ keyPair: KeyPairMaterial) throws {
        try identityStore.save(
            pseudonym: identityStore.pseudonym,
            verifyKey: keyPair.verifyKey,
            signKey: keyPair.signKey,
            encKey: keyPair.encKey,
            decKey: keyPair.decKey
        )
    }

    private static func generateKeyPairMaterial() -> KeyPairMaterial {
        let signingKeyPair = Curve25519.Signing.PrivateKey()
        let agreementKeyPair = Curve25519.KeyAgreement.PrivateKey()
        return KeyPairMaterial(
            verifyKey: signingKeyPair.publicKey.rawRepresentation,
            signKey: signingKeyPair.rawRepresentation,
            encKey: agreementKeyPair.publicKey.rawRepresentation,
            decKey: agreementKeyPair.rawRepresentation
        )
    }

    public func sign(_ message: Data) throws -> Data {
        let rawKey = try identityStore.signKey()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
        return try key.signature(for: message)
    }

    public func verify(_ message: Data, signature: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    public func encrypt(_ plaintext: Data, recipientEncKey: Data) throws -> Data {
        let rawKey = try identityStore.decKey()
        let myKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawKey)
        let theirKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientEncKey)
        let sharedSecret = try myKey.sharedSecretFromKeyAgreement(with: theirKey)

        let nonce = ChaChaPoly.Nonce()
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(nonce),
            sharedInfo: Data("deposplit-share".utf8),
            outputByteCount: 32
        )
        let sealedBox = try ChaChaPoly.seal(plaintext, using: symmetricKey, nonce: nonce)
        return Data([TransportSuite.current.rawValue]) + sealedBox.combined
    }

    public func decrypt(_ noncePlusCiphertext: Data, recipientEncKey: Data) throws -> Data {
        guard let tagByte = noncePlusCiphertext.first,
              let suite = TransportSuite(rawValue: tagByte) else {
            throw TransportSuiteError.unsupported(tag: noncePlusCiphertext.first ?? 0)
        }
        switch suite {
        case .x25519HkdfSha256ChaCha20Poly1305:
            break
        }
        let rawKey = try identityStore.decKey()
        let myKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawKey)
        let theirKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientEncKey)
        let sharedSecret = try myKey.sharedSecretFromKeyAgreement(with: theirKey)

        let sealedBox = try ChaChaPoly.SealedBox(combined: noncePlusCiphertext.dropFirst())
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(sealedBox.nonce),
            sharedInfo: Data("deposplit-share".utf8),
            outputByteCount: 32
        )
        return try ChaChaPoly.open(sealedBox, using: symmetricKey)
    }
}

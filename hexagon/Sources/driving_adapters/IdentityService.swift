import CryptoKit
import Foundation

public final class IdentityService: Identity, ShareEncryption {
    private let identityStore: any IdentityStore

    public init(identityStore: any IdentityStore) {
        self.identityStore = identityStore
    }

    public var isRegistered: Bool { identityStore.isRegistered }

    /// Derives each public key from its stored private half and compares it to the public key this
    /// device hands out. That single question covers every way the two can come apart: key storage
    /// emptied while the app's files survived a restore, a Keychain item that no longer reads, and
    /// public keys restored without the private ones.
    public var integrity: IdentityIntegrity {
        guard identityStore.isRegistered else { return .intact }
        do {
            let derivedVerifyKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: identityStore.signKey()
            ).publicKey.rawRepresentation
            let derivedEncKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: identityStore.decKey()
            ).publicKey.rawRepresentation
            let matches = derivedVerifyKey == identityStore.verifyKey && derivedEncKey == identityStore.encKey
            return matches ? .intact : .keysLost
        } catch AuthError.identityStorageUnavailable {
            return .unreadable
        } catch {
            return .keysLost
        }
    }
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
        try identityStore.rotate(
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

    /// Falls back to the `decKey` displaced by the last rotation when the current one cannot open
    /// the box. A share is sealed to whichever `encKey` the holder advertised at deposit time, so a
    /// holder who rotates between a deposit and their pickup would otherwise never be able to
    /// collect it: the row stays pending and every later poll fails identically. One generation is
    /// enough to cover that window without keeping a keyring.
    ///
    /// Never used for `encrypt` — this device always seals under its current key.
    public func decrypt(_ noncePlusCiphertext: Data, recipientEncKey: Data) throws -> Data {
        guard let tagByte = noncePlusCiphertext.first,
              let suite = TransportSuite(rawValue: tagByte) else {
            throw TransportSuiteError.unsupported(tag: noncePlusCiphertext.first ?? 0)
        }
        switch suite {
        case .x25519HkdfSha256ChaCha20Poly1305:
            break
        }
        do {
            return try Self.open(noncePlusCiphertext, recipientEncKey: recipientEncKey, decKey: try identityStore.decKey())
        } catch {
            // The current key's failure is the one worth reporting — the fallback missing or
            // failing too just means there was no earlier generation this box belongs to.
            guard let previous = identityStore.previousDecKey(),
                  let plaintext = try? Self.open(noncePlusCiphertext, recipientEncKey: recipientEncKey, decKey: previous)
            else { throw error }
            return plaintext
        }
    }

    private static func open(_ noncePlusCiphertext: Data, recipientEncKey: Data, decKey: Data) throws -> Data {
        let myKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: decKey)
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

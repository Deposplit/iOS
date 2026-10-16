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
            // The private keys are read first on purpose. They are the half that can distinguish
            // locked from empty, so reading the optional public keys ahead of them would report a
            // merely locked device as `.keysLost` — and `.keysLost` is what offers to mint a
            // replacement identity over a working one.
            let derivedVerifyKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: identityStore.signKey()
            ).publicKey.rawRepresentation
            let derivedEncKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: identityStore.decKey()
            ).publicKey.rawRepresentation
            guard let storedVerifyKey = identityStore.verifyKey, let storedEncKey = identityStore.encKey else {
                return .keysLost
            }
            return derivedVerifyKey == storedVerifyKey && derivedEncKey == storedEncKey ? .intact : .keysLost
        } catch AuthError.identityStorageUnavailable {
            return .unreadable
        } catch {
            return .keysLost
        }
    }
    public var pseudonym: String { identityStore.pseudonym }
    public var identityCreatedAt: Date? { identityStore.identityCreatedAt }
    public var verifyKey: Data? { identityStore.verifyKey }
    public var encKey: Data? { identityStore.encKey }

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
        try Self.seal(plaintext, recipientEncKey: recipientEncKey, info: Self.shareInfo)
    }

    public func sealLabel(_ label: String, recipientEncKey: Data) throws -> Data {
        try Self.seal(Data(label.utf8), recipientEncKey: recipientEncKey, info: Self.labelInfo)
    }

    /// Malformed UTF-8 decodes to replacement characters rather than failing, as on the other
    /// platforms. A label is only ever shown, and the signature over it has already proved who
    /// sealed it.
    public func openLabel(_ sealedLabel: Data) throws -> String {
        String(decoding: try unseal(sealedLabel, info: Self.labelInfo), as: UTF8.self)
    }

    /// Sealing involves no key of this device's own: HPKE draws a fresh ephemeral key for every
    /// box and discards it once the box is sealed, so not even this device can open what it sealed.
    private static func seal(_ plaintext: Data, recipientEncKey: Data, info: Data) throws -> Data {
        let recipientKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientEncKey)
        var sender = try HPKE.Sender(recipientKey: recipientKey, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info)
        let ciphertext = try sender.seal(plaintext)
        return Data([TransportSuite.current.rawValue]) + sender.encapsulatedKey + ciphertext
    }

    /// Falls back to the `decKey` displaced by the last rotation when the current one cannot open
    /// the box. A share is sealed to whichever `encKey` the holder advertised at deposit time, so a
    /// holder who rotates between a deposit and their pickup would otherwise never be able to
    /// collect it: the row stays pending and every later poll fails identically. One generation is
    /// enough to cover that window without keeping a keyring.
    public func decrypt(_ box: Data) throws -> Data {
        try unseal(box, info: Self.shareInfo)
    }

    private func unseal(_ box: Data, info: Data) throws -> Data {
        guard let tagByte = box.first, let suite = TransportSuite(rawValue: tagByte) else {
            throw TransportSuiteError.unsupported(tag: box.first ?? 0)
        }
        switch suite {
        case .hpkeX25519Sha256ChaCha20Poly1305:
            break
        }
        do {
            return try Self.open(box, decKey: try identityStore.decKey(), info: info)
        } catch {
            // The current key's failure is the one worth reporting — the fallback missing or
            // failing too just means there was no earlier generation this box belongs to.
            guard let previous = identityStore.previousDecKey(),
                  let plaintext = try? Self.open(box, decKey: previous, info: info)
            else { throw error }
            return plaintext
        }
    }

    private static func open(_ box: Data, decKey: Data, info: Data) throws -> Data {
        let body = box.dropFirst()
        guard body.count >= encapsulatedKeyBytes else { throw CryptoKitError.incorrectParameterSize }
        let encapsulatedKey = Data(body.prefix(encapsulatedKeyBytes))
        let ciphertext = Data(body.dropFirst(encapsulatedKeyBytes))
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: decKey)
        var recipient = try HPKE.Recipient(
            privateKey: privateKey, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info, encapsulatedKey: encapsulatedKey
        )
        return try recipient.open(ciphertext)
    }

    /// DHKEM(X25519)'s encapsulated key: the ephemeral public key, 32 bytes.
    private static let encapsulatedKeyBytes = 32
    private static let shareInfo = Data("deposplit-share".utf8)
    /// HPKE info of its own, so a sealed label can never be opened as a sealed share.
    private static let labelInfo = Data("deposplit-label".utf8)
}

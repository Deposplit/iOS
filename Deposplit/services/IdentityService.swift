import CryptoKit
import Foundation

final class IdentityService: Identity {
    private let identityStore: IdentityStore

    init(identityStore: IdentityStore) {
        self.identityStore = identityStore
    }

    var isRegistered: Bool { identityStore.isRegistered }
    var pseudonym: String { identityStore.pseudonym }
    var edPublicKey: Data { identityStore.edPublicKey }
    var xPublicKey: Data { identityStore.xPublicKey }

    func register(pseudonym: String) throws {
        let edKey = Curve25519.Signing.PrivateKey()
        let xKey = Curve25519.KeyAgreement.PrivateKey()
        try identityStore.save(
            pseudonym: pseudonym,
            edPk: edKey.publicKey.rawRepresentation,
            edSk: edKey.rawRepresentation,
            xPk: xKey.publicKey.rawRepresentation,
            xSk: xKey.rawRepresentation
        )
    }

    func sign(_ message: Data) throws -> Data {
        let rawKey = try identityStore.edPrivateKey()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
        return try key.signature(for: message)
    }

    func encrypt(_ plaintext: Data, recipientXPublicKey: Data) throws -> Data {
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

    func decrypt(_ noncePlusCiphertext: Data, recipientXPublicKey: Data) throws -> Data {
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

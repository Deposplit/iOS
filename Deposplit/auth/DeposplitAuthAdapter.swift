import Foundation
import CryptoKit
import Security

enum AuthError: Error {
    case keychainSave(OSStatus)
    case keychainLoad(OSStatus)
    case notRegistered
    case invalidKeyData
    case encryptionFailed
    case decryptionFailed
}

final class DeposplitAuthAdapter: AuthPort {

    private enum Keys {
        static let registered = "deposplit.registered"
        static let pseudonymKey = "deposplit.pseudonym"
        static let edPublicKeyAccount = "ed.public"
        static let edPrivateKeyAccount = "ed.private"
        static let xPublicKeyAccount = "x.public"
        static let xPrivateKeyAccount = "x.private"
        static let service = "com.deposplit.Deposplit"
    }

    var isRegistered: Bool {
        UserDefaults.standard.bool(forKey: Keys.registered)
    }

    func register(pseudonym: String) throws {
        let edKey = Curve25519.Signing.PrivateKey()
        let xKey = Curve25519.KeyAgreement.PrivateKey()

        try saveToKeychain(edKey.rawRepresentation, account: Keys.edPrivateKeyAccount)
        try saveToKeychain(edKey.publicKey.rawRepresentation, account: Keys.edPublicKeyAccount)
        try saveToKeychain(xKey.rawRepresentation, account: Keys.xPrivateKeyAccount)
        try saveToKeychain(xKey.publicKey.rawRepresentation, account: Keys.xPublicKeyAccount)

        UserDefaults.standard.set(pseudonym, forKey: Keys.pseudonymKey)
        UserDefaults.standard.set(true, forKey: Keys.registered)
    }

    var pseudonym: String {
        UserDefaults.standard.string(forKey: Keys.pseudonymKey) ?? ""
    }

    var edPublicKey: Data {
        (try? loadFromKeychain(account: Keys.edPublicKeyAccount)) ?? Data()
    }

    var xPublicKey: Data {
        (try? loadFromKeychain(account: Keys.xPublicKeyAccount)) ?? Data()
    }

    func sign(_ message: Data) throws -> Data {
        let rawKey = try loadFromKeychain(account: Keys.edPrivateKeyAccount)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
        return try key.signature(for: message)
    }

    func encrypt(_ plaintext: Data, recipientXPublicKey: Data) throws -> Data {
        let rawKey = try loadFromKeychain(account: Keys.xPrivateKeyAccount)
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
        let rawKey = try loadFromKeychain(account: Keys.xPrivateKeyAccount)
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

    // MARK: - Keychain helpers

    private func saveToKeychain(_ data: Data, account: String) throws {
        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keys.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keys.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw AuthError.keychainSave(status) }
    }

    private func loadFromKeychain(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keys.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw AuthError.keychainLoad(status)
        }
        return data
    }
}

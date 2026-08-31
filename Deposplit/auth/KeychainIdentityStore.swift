import hexagon
import Foundation
import Security

final class KeychainIdentityStore: IdentityStore {
    private enum Keys {
        static let registered = "deposplit.registered"
        static let pseudonymKey = "deposplit.pseudonym"
        static let verifyKeyAccount = "verify.public"
        static let signKeyAccount = "sign.private"
        static let encKeyAccount = "enc.public"
        static let decKeyAccount = "dec.private"
        static let previousDecKeyAccount = "dec.private.previous"
        static let service = "com.deposplit.Deposplit"
    }

    var isRegistered: Bool {
        UserDefaults.standard.bool(forKey: Keys.registered)
    }

    func save(pseudonym: String, verifyKey: Data, signKey: Data, encKey: Data, decKey: Data) throws {
        try saveToKeychain(signKey, account: Keys.signKeyAccount)
        try saveToKeychain(verifyKey, account: Keys.verifyKeyAccount)
        try saveToKeychain(decKey, account: Keys.decKeyAccount)
        try saveToKeychain(encKey, account: Keys.encKeyAccount)
        deleteFromKeychain(account: Keys.previousDecKeyAccount)
        UserDefaults.standard.set(pseudonym, forKey: Keys.pseudonymKey)
        UserDefaults.standard.set(true, forKey: Keys.registered)
    }

    /// The displaced `decKey` is written first: a crash between the two writes leaves a previous
    /// slot that merely duplicates the current key, which decrypts nothing extra. Writing it last
    /// would risk the opposite — a rotated identity with no fallback at all.
    func rotate(verifyKey: Data, signKey: Data, encKey: Data, decKey: Data) throws {
        if let displaced = try? loadFromKeychain(account: Keys.decKeyAccount) {
            try saveToKeychain(displaced, account: Keys.previousDecKeyAccount)
        } else {
            deleteFromKeychain(account: Keys.previousDecKeyAccount)
        }
        try saveToKeychain(signKey, account: Keys.signKeyAccount)
        try saveToKeychain(verifyKey, account: Keys.verifyKeyAccount)
        try saveToKeychain(decKey, account: Keys.decKeyAccount)
        try saveToKeychain(encKey, account: Keys.encKeyAccount)
    }

    func previousDecKey() -> Data? {
        try? loadFromKeychain(account: Keys.previousDecKeyAccount)
    }

    var pseudonym: String {
        UserDefaults.standard.string(forKey: Keys.pseudonymKey) ?? ""
    }

    var verifyKey: Data {
        (try? loadFromKeychain(account: Keys.verifyKeyAccount)) ?? Data()
    }

    var encKey: Data {
        (try? loadFromKeychain(account: Keys.encKeyAccount)) ?? Data()
    }

    func signKey() throws -> Data {
        try loadFromKeychain(account: Keys.signKeyAccount)
    }

    func decKey() throws -> Data {
        try loadFromKeychain(account: Keys.decKeyAccount)
    }

    private func deleteFromKeychain(account: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keys.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }

    private func saveToKeychain(_ data: Data, account: String) throws {
        deleteFromKeychain(account: account)

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

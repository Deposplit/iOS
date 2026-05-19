import hexagon
import Foundation
import Security

final class KeychainIdentityStore: IdentityStore {
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

    func save(pseudonym: String, edPk: Data, edSk: Data, xPk: Data, xSk: Data) throws {
        try saveToKeychain(edSk, account: Keys.edPrivateKeyAccount)
        try saveToKeychain(edPk, account: Keys.edPublicKeyAccount)
        try saveToKeychain(xSk, account: Keys.xPrivateKeyAccount)
        try saveToKeychain(xPk, account: Keys.xPublicKeyAccount)
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

    func edPrivateKey() throws -> Data {
        try loadFromKeychain(account: Keys.edPrivateKeyAccount)
    }

    func xPrivateKey() throws -> Data {
        try loadFromKeychain(account: Keys.xPrivateKeyAccount)
    }

    private func saveToKeychain(_ data: Data, account: String) throws {
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

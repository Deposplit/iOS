import Foundation

public enum AuthError: Error {
    case keychainSave(OSStatus)
    case keychainLoad(OSStatus)
    /// Key material could not be read *right now* — a locked device, a Keychain not yet available —
    /// as opposed to not being there at all. Only the adapter sees the platform's own status code,
    /// so only the adapter can tell them apart. See `IdentityIntegrity.unreadable`.
    case identityStorageUnavailable(OSStatus)
    case notRegistered
    case invalidKeyData
    case encryptionFailed
    case decryptionFailed
}

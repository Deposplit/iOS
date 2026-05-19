import Foundation

public enum AuthError: Error {
    case keychainSave(OSStatus)
    case keychainLoad(OSStatus)
    case notRegistered
    case invalidKeyData
    case encryptionFailed
    case decryptionFailed
}

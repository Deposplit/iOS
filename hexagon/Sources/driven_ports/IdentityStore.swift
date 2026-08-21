import Foundation

public protocol IdentityStore {
    var isRegistered: Bool { get }
    func save(pseudonym: String, verifyKey: Data, signKey: Data, encKey: Data, decKey: Data) throws
    var pseudonym: String { get }
    var verifyKey: Data { get }
    var encKey: Data { get }
    func signKey() throws -> Data
    func decKey() throws -> Data
}

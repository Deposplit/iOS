import Foundation

protocol IdentityStore {
    var isRegistered: Bool { get }
    func save(pseudonym: String, edPk: Data, edSk: Data, xPk: Data, xSk: Data) throws
    var pseudonym: String { get }
    var edPublicKey: Data { get }
    var xPublicKey: Data { get }
    func edPrivateKey() throws -> Data
    func xPrivateKey() throws -> Data
}

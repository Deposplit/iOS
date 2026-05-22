import Foundation

public protocol ContactManagement {
    func listContacts() throws -> [Contact]
    func addManually(pseudonym: String, edPublicKey: Data, xPublicKey: Data) throws
    func addFromQr(pseudonym: String, edPublicKey: Data, xPublicKey: Data) throws
    func deleteContact(contactId: UUID) throws
}

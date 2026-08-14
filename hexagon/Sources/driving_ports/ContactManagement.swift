import Foundation

public protocol ContactManagement {
    func listContacts() throws -> [Contact]
    func addManually(pseudonym: String, edPublicKey: Data, xPublicKey: Data, verificationLevel: VerificationLevel, relayBaseUrl: String?) throws
    func addFromQr(pseudonym: String, edPublicKey: Data, xPublicKey: Data, verificationLevel: VerificationLevel, relayBaseUrl: String?) throws
    func deleteContact(contactId: UUID) throws
}

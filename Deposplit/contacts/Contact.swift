import Foundation

enum VerificationLevel: String, Codable {
    case unverified, verified
}

struct Contact: Identifiable, Equatable {
    let id: UUID
    let pseudonym: String
    let edPublicKey: Data
    let xPublicKey: Data
    let verificationLevel: VerificationLevel
    let verifiedAt: String?
    let addedAt: String
}

protocol ContactRepository {
    func getAll() -> [Contact]
    func getByEdKey(_ edPublicKey: Data) -> Contact?
    func save(_ contact: Contact)
    func delete(contactId: UUID)
}

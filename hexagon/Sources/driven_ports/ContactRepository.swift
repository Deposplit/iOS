import Foundation

public protocol ContactRepository {
    func getAll() -> [Contact]
    func getByVerifyKey(_ verifyKey: Data) -> Contact?
    func getById(_ id: UUID) -> Contact?
    func save(_ contact: Contact)
    func delete(contactId: UUID)
}

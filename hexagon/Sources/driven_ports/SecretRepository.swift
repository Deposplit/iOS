import Foundation

/// Local store of sender-side `Secret` aggregates. Purely local: the relay never stores
/// `Secret`, only opaque `ShareRequest` rows.
public protocol SecretRepository {
    func getAll() throws -> [Secret]
    func save(_ secret: Secret) throws
    func delete(secretId: UUID) throws
}

import Foundation

/// Local store of sender-side `Secret` aggregates — see deposplit.com/CLAUDE.md "What is next"
/// item 11. Purely local: the relay never stores `Secret`, only opaque `ShareRequest` rows.
public protocol SecretRepository {
    func getAll() throws -> [Secret]
    func save(_ secret: Secret) throws
    func delete(secretId: UUID) throws
}

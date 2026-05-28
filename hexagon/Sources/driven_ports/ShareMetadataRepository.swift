import Foundation

public protocol ShareMetadataRepository {
    func getAll() throws -> [ShareMetadata]
    func save(_ share: ShareMetadata) throws
    func delete(shareId: UUID) throws
}

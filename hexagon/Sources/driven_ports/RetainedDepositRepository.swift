import Foundation

public protocol RetainedDepositRepository {
    func getAll() throws -> [RetainedDepositBlob]
    func save(_ blob: RetainedDepositBlob) throws
    func delete(id: UUID) throws
}

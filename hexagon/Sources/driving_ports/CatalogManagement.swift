import Foundation

/// Optional catalog export/import (item 8) — a convenience backup of the *non-secret* catalog,
/// never shares or private keys.
public protocol CatalogManagement {
    func exportCatalog() throws -> Data
    /// Merges contacts/secrets/shareMetadata from `data` into local storage — upsert-if-absent
    /// only, by id; an existing local record is never overwritten by an imported one, since a
    /// stale backup could otherwise clobber more-current local state. Returns the number of
    /// newly added contacts.
    func importCatalog(_ data: Data) throws -> Int
}

import Foundation

/// The outcome of `ShareManagement.reconstruct`'s over-determination cross-check.
/// `.noMargin` means exactly `k` shares were available (no surplus to check against — the
/// "reconstructed without integrity margin" case). `.confirmed` means more than `k` were
/// collected and all of them agreed. `.excludedSuspects` means more than `k` were collected, at
/// least one disagreed, and the disagreeing share(s) were identified and excluded — the
/// reconstructed secret still comes from a group large enough to make that exclusion provably
/// correct (see `combineWithIntegrity`), not a guess.
public enum ReconstructionIntegrity: Equatable {
    case noMargin
    case confirmed
    case excludedSuspects(excludedContactIds: Set<UUID>)
}

/// `mimeType` is the owner's own record of what she split, carried alongside the bytes so a caller
/// deciding how to render them never has to go back to the `Secret` aggregate and risk pairing
/// bytes with the wrong type.
public struct ReconstructionResult: Equatable {
    public let secret: Data
    public let integrity: ReconstructionIntegrity
    public let mimeType: MimeType

    public init(secret: Data, integrity: ReconstructionIntegrity, mimeType: MimeType) {
        self.secret = secret
        self.integrity = integrity
        self.mimeType = mimeType
    }
}

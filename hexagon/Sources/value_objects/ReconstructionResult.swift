import Foundation

/// Item 13 — the outcome of `ShareManagement.reconstruct`'s over-determination cross-check.
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

public struct ReconstructionResult: Equatable {
    public let secret: Data
    public let integrity: ReconstructionIntegrity

    public init(secret: Data, integrity: ReconstructionIntegrity) {
        self.secret = secret
        self.integrity = integrity
    }
}

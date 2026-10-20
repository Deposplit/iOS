import Foundation

/// A relay that answered, but with an error status. A `ShareRelay` adapter throws this for such an
/// answer and for nothing else, which is what lets a sync pass tell a refusal from silence:
/// anything else an adapter throws means the relay did not answer at all.
public enum RelayError: Error, LocalizedError {
    case refused(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .refused(let statusCode, let body): "HTTP \(statusCode): \(body)"
        }
    }
}

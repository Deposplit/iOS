import Foundation

/// The rows every relay that answered returned, and the base URLs of those that did not. A list
/// read from the relays alone has nothing local to fall back on, so the caller needs both halves:
/// a partial list is still worth showing, and each missing relay is worth naming. `anyAnswered`
/// separates that from a list that is empty only because nobody could be asked.
public struct RelayFanOut<T> {
    public let items: [T]
    public let unreachableRelays: Set<String>
    public let anyAnswered: Bool

    public init(items: [T], unreachableRelays: Set<String>, anyAnswered: Bool) {
        self.items = items
        self.unreachableRelays = unreachableRelays
        self.anyAnswered = anyAnswered
    }

    public func mapItems<R>(_ transform: ([T]) -> [R]) -> RelayFanOut<R> {
        RelayFanOut<R>(items: transform(items), unreachableRelays: unreachableRelays, anyAnswered: anyAnswered)
    }
}

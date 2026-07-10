import hexagon
import Foundation

/// Memoizes one `DeposplitApiAdapter` per resolved base URL so HTTP clients aren't rebuilt on
/// every call. `nil` resolves to `RelaySettings`'s runtime-configurable default.
final class DeposplitRelayResolver: ShareRelayResolver {

    private let identity: any Identity
    private let relaySettings: any RelaySettings
    private var cache: [String: any ShareRelay] = [:]

    init(identity: any Identity, relaySettings: any RelaySettings) {
        self.identity = identity
        self.relaySettings = relaySettings
    }

    func resolve(_ relayBaseUrl: String?) -> any ShareRelay {
        let url = relayBaseUrl ?? relaySettings.defaultRelayBaseURL()
        if let cached = cache[url] { return cached }
        let relay = DeposplitApiAdapter(identity: identity, baseURL: url)
        cache[url] = relay
        return relay
    }
}

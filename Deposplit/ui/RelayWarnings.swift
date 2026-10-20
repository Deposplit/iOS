import SwiftUI

/// A relay as a person would recognise it: its host, and its port when it has one. The scheme and
/// any path add length without telling two relays apart. Falls back to the URL as stored, since a
/// warning that names a relay oddly is still better than one that names none.
func relayName(_ baseUrl: String) -> String {
    guard let components = URLComponents(string: baseUrl), let host = components.host else { return baseUrl }
    return components.port.map { "\(host):\($0)" } ?? host
}

/// A relay that answered with an error, and the status it gave: what its warning names.
struct RefusingRelay: Hashable {
    let baseUrl: String
    let statusCode: Int

    /// One per relay, in the order the warnings show them. A relay several reports name keeps the
    /// status the first of them gave.
    static func list(_ reports: [String: Int]...) -> [RefusingRelay] {
        reports
            .reduce(into: [String: Int]()) { merged, report in merged.merge(report) { first, _ in first } }
            .map { RefusingRelay(baseUrl: $0.key, statusCode: $0.value) }
            .sorted { $0.baseUrl < $1.baseUrl }
    }
}

/// One soft warning line, the kind that sits over real content rather than replacing it.
struct SoftWarningRow: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .imageScale(.small)
            Text(text)
                .font(.caption)
            Spacer()
        }
        .foregroundStyle(.red)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        Divider()
    }
}

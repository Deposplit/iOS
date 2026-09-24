import SwiftUI

/// A relay as a person would recognise it: its host, and its port when it has one. The scheme and
/// any path add length without telling two relays apart. Falls back to the URL as stored, since a
/// warning that names a relay oddly is still better than one that names none.
func relayName(_ baseUrl: String) -> String {
    guard let components = URLComponents(string: baseUrl), let host = components.host else { return baseUrl }
    return components.port.map { "\(host):\($0)" } ?? host
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
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        Divider()
    }
}

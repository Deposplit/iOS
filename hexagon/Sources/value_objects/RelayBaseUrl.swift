import Foundation

/// What names a relay: an `http` or `https` URL with a host, and nothing after its path.
///
/// Every request is this string with an endpoint's path appended, so a query or a fragment would
/// swallow that path, and a trailing slash would double the one it starts with. Anything else —
/// `172.22.114.13:9000` without its scheme, a `file:` URL — is refused where it is entered rather
/// than stored, because once stored it fails on every sync for as long as the contact exists.
///
/// Android's and phon's `RelayBaseUrl` apply the same rule through `java.net.URI`, which is why
/// invalid characters are refused here instead of percent-encoded.
public enum RelayBaseUrl {

    /// The relay `input` names, trimmed and without trailing slashes, or nil when it names none.
    public static func parse(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: trimmed, encodingInvalidCharacters: false),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { return nil }
        var base = trimmed
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }
}

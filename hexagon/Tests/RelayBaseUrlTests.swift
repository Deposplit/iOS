import Testing
@testable import hexagon

// The rule every way of naming a relay is checked against. Android's and phon's RelayBaseUrl tests
// hold the same cases, so a relay one platform accepts another does not refuse.

@Test func relayBaseUrlAcceptsHttpAndHttpsWithAHostAPortAndAPath() {
    #expect(RelayBaseUrl.parse("https://api.deposplit.com") == "https://api.deposplit.com")
    #expect(RelayBaseUrl.parse("http://172.22.114.13:9000") == "http://172.22.114.13:9000")
    #expect(RelayBaseUrl.parse("https://example.org/deposplit") == "https://example.org/deposplit")
    #expect(RelayBaseUrl.parse("http://[::1]:9000") == "http://[::1]:9000")
    #expect(RelayBaseUrl.parse("HTTPS://Relay.Example") == "HTTPS://Relay.Example")
}

/// Every request appends a path that starts with a slash, so one left on the end would double it.
@Test func relayBaseUrlTrimsWhitespaceAndTrailingSlashes() {
    #expect(RelayBaseUrl.parse("  https://relay.example/ \n") == "https://relay.example")
    #expect(RelayBaseUrl.parse("https://example.org/deposplit//") == "https://example.org/deposplit")
}

@Test func relayBaseUrlRefusesAnAddressWithoutAnHttpScheme() {
    #expect(RelayBaseUrl.parse("172.22.114.13:9000") == nil)
    #expect(RelayBaseUrl.parse("localhost:9000") == nil)
    #expect(RelayBaseUrl.parse("relay.example") == nil)
    #expect(RelayBaseUrl.parse("file:///etc/hosts") == nil)
    #expect(RelayBaseUrl.parse("ftp://relay.example") == nil)
}

@Test func relayBaseUrlRefusesAnAddressWithoutAHost() {
    #expect(RelayBaseUrl.parse("") == nil)
    #expect(RelayBaseUrl.parse("http://") == nil)
    #expect(RelayBaseUrl.parse("http:///share-requests") == nil)
}

@Test func relayBaseUrlRefusesUserInfoAQueryOrAFragment() {
    #expect(RelayBaseUrl.parse("https://user:secret@relay.example") == nil)
    #expect(RelayBaseUrl.parse("https://relay.example?region=eu") == nil)
    #expect(RelayBaseUrl.parse("https://relay.example#top") == nil)
}

@Test func relayBaseUrlRefusesCharactersAUrlCannotHold() {
    #expect(RelayBaseUrl.parse("https://relay example.com") == nil)
    #expect(RelayBaseUrl.parse("https://bücher.example") == nil)
}

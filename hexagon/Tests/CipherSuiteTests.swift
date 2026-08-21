import Testing
@testable import hexagon

// Item 14 ("crypto agility") — CipherSuite's wire round-trip, mirroring ShareTransactionType's
// existing String-raw-value pattern.

@Test func cipherSuiteWireValueRoundTrips() {
    #expect(CipherSuite.ed25519X25519V1.rawValue == "ed25519+x25519-v1")
    #expect(CipherSuite(rawValue: "ed25519+x25519-v1") == .ed25519X25519V1)
}

@Test func cipherSuiteRejectsAnUnknownWireValue() {
    #expect(CipherSuite(rawValue: "made-up-suite") == nil)
}

@Test func cipherSuiteCurrentIsEd25519X25519V1WithThirtyTwoByteKeys() {
    #expect(CipherSuite.current == .ed25519X25519V1)
    #expect(CipherSuite.current.verifyKeyLength == 32)
    #expect(CipherSuite.current.encKeyLength == 32)
}

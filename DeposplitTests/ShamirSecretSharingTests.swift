import Testing
@testable import Deposplit

// -------------------------------------------------------------------------
// Round-trip tests
// -------------------------------------------------------------------------

@Test func splitAndCombineRoundTripsFor2of3() throws {
    let secret: [UInt8] = Array("Hello, Deposplit!".utf8)
    let shares = try split(secret: secret, shares: 3, threshold: 2)
    #expect(try combine(shares: Array(shares.prefix(2))) == secret)
    #expect(try combine(shares: Array(shares.suffix(2))) == secret)
    #expect(try combine(shares: [shares[0], shares[2]]) == secret)
}

@Test func splitAndCombineRoundTripsFor3of5() throws {
    let secret: [UInt8] = (0..<32).map { UInt8($0) }
    let shares = try split(secret: secret, shares: 5, threshold: 3)
    #expect(try combine(shares: Array(shares.prefix(3))) == secret)
    #expect(try combine(shares: Array(shares.suffix(3))) == secret)
    #expect(try combine(shares: [shares[0], shares[2], shares[4]]) == secret)
}

@Test func splitAndCombineRoundTripsFor255of255() throws {
    let secret: [UInt8] = [0x42]
    let shares = try split(secret: secret, shares: 255, threshold: 255)
    #expect(try combine(shares: shares) == secret)
}

@Test func splitAndCombineRoundTripsForSingleByte() throws {
    let secret: [UInt8] = [0xff]
    let shares = try split(secret: secret, shares: 2, threshold: 2)
    #expect(try combine(shares: shares) == secret)
}

@Test func combiningMoreThanThresholdSharesAlsoWorks() throws {
    let secret: [UInt8] = Array("extra shares are fine".utf8)
    let shares = try split(secret: secret, shares: 5, threshold: 3)
    #expect(try combine(shares: shares) == secret)
}

// -------------------------------------------------------------------------
// Cross-platform test vectors
//
// These vectors are derived by hand from the GF(2^8) arithmetic and verify
// that combine() is implemented correctly. They use the polynomial
// f(x) = secret_byte + 0x01·x in GF(2^8) with x-coordinates [1, 2],
// which is the simplest non-trivial 2-of-2 case (threshold = 2, degree = 1,
// leading coefficient c₁ = 0x01).
//
// These same vectors are tested in the Kotlin port to confirm byte-for-byte
// cross-platform compatibility of combine().
// -------------------------------------------------------------------------

@Test func crossPlatformVector1ZeroSecretByte() throws {
    // secret = [0x00]
    // f(x) = 0x00 + 0x01·x  →  f(1) = 0x01, f(2) = 0x02
    let shares: [[UInt8]] = [
        [0x01, 0x01],   // y = 0x01, x = 0x01
        [0x02, 0x02],   // y = 0x02, x = 0x02
    ]
    #expect(try combine(shares: shares) == [0x00])
}

@Test func crossPlatformVector2NonZeroSecretByte() throws {
    // secret = [0x41]  ('A')
    // f(x) = 0x41 + 0x01·x  →  f(1) = 0x40, f(2) = 0x43
    let shares: [[UInt8]] = [
        [0x40, 0x01],   // y = 0x40, x = 0x01
        [0x43, 0x02],   // y = 0x43, x = 0x02
    ]
    #expect(try combine(shares: shares) == [0x41])
}

@Test func crossPlatformVector3MultiByteSecret() throws {
    // secret = [0x00, 0x41]
    // Byte 0: f(x) = 0x00 + 0x01·x  →  f(1) = 0x01, f(2) = 0x02
    // Byte 1: f(x) = 0x41 + 0x01·x  →  f(1) = 0x40, f(2) = 0x43
    let shares: [[UInt8]] = [
        [0x01, 0x40, 0x01],  // [y₀, y₁, x] for x = 0x01
        [0x02, 0x43, 0x02],  // [y₀, y₁, x] for x = 0x02
    ]
    #expect(try combine(shares: shares) == [0x00, 0x41])
}

// -------------------------------------------------------------------------
// Input validation — split()
// -------------------------------------------------------------------------

@Test func splitRejectsEmptySecret() {
    #expect(throws: ShamirError.emptySecret) {
        try split(secret: [], shares: 2, threshold: 2)
    }
}

@Test func splitRejectsSharesBelow2() {
    #expect(throws: ShamirError.sharesOutOfRange) {
        try split(secret: [0x01], shares: 1, threshold: 1)
    }
}

@Test func splitRejectsSharesAbove255() {
    #expect(throws: ShamirError.sharesOutOfRange) {
        try split(secret: [0x01], shares: 256, threshold: 2)
    }
}

@Test func splitRejectsThresholdBelow2() {
    #expect(throws: ShamirError.thresholdOutOfRange) {
        try split(secret: [0x01], shares: 2, threshold: 1)
    }
}

@Test func splitRejectsThresholdAbove255() {
    #expect(throws: ShamirError.thresholdOutOfRange) {
        try split(secret: [0x01], shares: 255, threshold: 256)
    }
}

@Test func splitRejectsThresholdGreaterThanShares() {
    #expect(throws: ShamirError.sharesLessThanThreshold) {
        try split(secret: [0x01], shares: 2, threshold: 3)
    }
}

// -------------------------------------------------------------------------
// Input validation — combine()
// -------------------------------------------------------------------------

@Test func combineRejectsFewerThan2Shares() {
    #expect(throws: ShamirError.tooFewCombineShares) {
        try combine(shares: [[0x01, 0x02]])
    }
}

@Test func combineRejectsSharesTooShort() {
    #expect(throws: ShamirError.sharesTooShort) {
        try combine(shares: [[0x01], [0x02]])
    }
}

@Test func combineRejectsSharesWithMismatchedLengths() {
    #expect(throws: ShamirError.unequalShareLengths) {
        try combine(shares: [[0x01, 0x02], [0x01, 0x02, 0x03]])
    }
}

@Test func combineRejectsDuplicateXCoordinates() {
    // Both shares have x = 0x05 (last byte)
    #expect(throws: ShamirError.duplicateXCoordinate) {
        try combine(shares: [[0x01, 0x05], [0x02, 0x05]])
    }
}

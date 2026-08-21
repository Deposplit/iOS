import Testing
@testable import hexagon

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

// -------------------------------------------------------------------------
// combineWithIntegrity() — item 13 (reconstruction integrity via over-determination)
// -------------------------------------------------------------------------

/// Corrupts every secret byte of a share (leaving its x-coordinate intact), simulating a
/// tampered/forged/bit-flipped holder response — wrong as a whole, not selectively per-byte.
private func tamper(_ share: [UInt8]) -> [UInt8] {
    var tampered = share
    for i in 0..<(tampered.count - 1) {
        tampered[i] = tampered[i] &+ 1
    }
    return tampered
}

@Test func combineWithIntegrityAtExactlyThresholdHasNoMargin() throws {
    let secret: [UInt8] = Array("no margin here".utf8)
    let shares = try split(secret: secret, shares: 4, threshold: 4)
    let result = try combineWithIntegrity(shares: shares, threshold: 4)
    #expect(result.secret == secret)
    #expect(result.hasIntegrityMargin == false)
    #expect(result.excludedIndices.isEmpty)
}

@Test func combineWithIntegrityWithSurplusAllConsistentIsConfirmed() throws {
    let secret: [UInt8] = Array("all agree".utf8)
    let shares = try split(secret: secret, shares: 5, threshold: 4)
    let result = try combineWithIntegrity(shares: shares, threshold: 4)
    #expect(result.secret == secret)
    #expect(result.hasIntegrityMargin == true)
    #expect(result.excludedIndices.isEmpty)
}

@Test func combineWithIntegrityAtMargin1WithOneBadShareDetectsButCannotCorrect() throws {
    // threshold+1 collected, one bad: can only *detect* a problem exists (CLAUDE.md item 13),
    // never identify which side is at fault — must throw rather than guess.
    let secret: [UInt8] = Array("margin one".utf8)
    var shares = try split(secret: secret, shares: 5, threshold: 4)
    shares[0] = tamper(shares[0])
    do {
        _ = try combineWithIntegrity(shares: shares, threshold: 4)
        Issue.record("expected reconstructionIntegrityFailed to be thrown")
    } catch let ShamirError.reconstructionIntegrityFailed(largestConsistentGroup, totalShares) {
        #expect(totalShares == 5)
        #expect(largestConsistentGroup == 4)
    }
}

@Test func combineWithIntegrityAtMargin2WithOneBadShareExcludesItAndReconstructs() throws {
    let secret: [UInt8] = Array("margin two corrects one bad share".utf8)
    var shares = try split(secret: secret, shares: 6, threshold: 4)
    shares[2] = tamper(shares[2])
    let result = try combineWithIntegrity(shares: shares, threshold: 4)
    #expect(result.secret == secret)
    #expect(result.hasIntegrityMargin == true)
    #expect(result.excludedIndices == [2])
}

@Test func combineWithIntegrityAtMargin3WithTwoBadSharesExceedsCorrectableBound() throws {
    // ⌊margin/2⌋ = ⌊3/2⌋ = 1 correctable — two simultaneous bad shares exceed it, so this must
    // refuse to guess rather than silently pick a spurious "majority".
    let secret: [UInt8] = Array("margin three cannot correct two bad".utf8)
    var shares = try split(secret: secret, shares: 7, threshold: 4)
    shares[1] = tamper(shares[1])
    shares[5] = tamper(shares[5])
    do {
        _ = try combineWithIntegrity(shares: shares, threshold: 4)
        Issue.record("expected reconstructionIntegrityFailed to be thrown")
    } catch let ShamirError.reconstructionIntegrityFailed(largestConsistentGroup, totalShares) {
        #expect(totalShares == 7)
        #expect(largestConsistentGroup < 6) // would need >=6 to be accepted at this margin
    }
}

@Test func combineWithIntegrityAtMargin4WithTwoBadSharesExcludesBothAndReconstructs() throws {
    let secret: [UInt8] = Array("margin four corrects two bad shares".utf8)
    var shares = try split(secret: secret, shares: 8, threshold: 4)
    shares[0] = tamper(shares[0])
    shares[7] = tamper(shares[7])
    let result = try combineWithIntegrity(shares: shares, threshold: 4)
    #expect(result.secret == secret)
    #expect(result.hasIntegrityMargin == true)
    #expect(result.excludedIndices == [0, 7])
}

@Test func combineWithIntegrityValidatesLikeCombine() {
    #expect(throws: ShamirError.tooFewCombineShares) {
        try combineWithIntegrity(shares: [[0x01, 0x02]], threshold: 2)
    }
    #expect(throws: ShamirError.sharesTooShort) {
        try combineWithIntegrity(shares: [[0x01], [0x02]], threshold: 2)
    }
    #expect(throws: ShamirError.unequalShareLengths) {
        try combineWithIntegrity(shares: [[0x01, 0x02], [0x01, 0x02, 0x03]], threshold: 2)
    }
    #expect(throws: ShamirError.duplicateXCoordinate) {
        try combineWithIntegrity(shares: [[0x01, 0x05], [0x02, 0x05], [0x03, 0x05]], threshold: 2)
    }
}

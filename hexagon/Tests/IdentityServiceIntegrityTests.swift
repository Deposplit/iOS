import Testing
@testable import hexagon
import Foundation

// Raw OSStatus values rather than the errSec… constants: those live in Security, which the hexagon
// does not import.
private let itemNotFound: OSStatus = -25300        // errSecItemNotFound
private let interactionNotAllowed: OSStatus = -25308 // errSecInteractionNotAllowed

/// A store that can be put into the states a phone switch produces: app storage restored, private
/// key material gone or belonging to some other identity, or readable only once the device is
/// unlocked.
private final class RestorableIdentityStore: IdentityStore {
    private(set) var isRegistered = false
    private var _pseudonym = ""
    private var _verifyKey = Data()
    fileprivate var _signKey = Data()
    private var _encKey = Data()
    fileprivate var _decKey = Data()
    private var _previousDecKey: Data?

    /// Thrown by every private-key read, standing in for key storage that no longer yields its
    /// contents.
    var privateKeyFailure: Error?

    /// Key storage that is locked hides the public keys as well, not only the private ones.
    var publicKeysReadable = true

    var pseudonym: String { _pseudonym }
    var verifyKey: Data? { publicKeysReadable ? _verifyKey : nil }
    var encKey: Data? { publicKeysReadable ? _encKey : nil }

    func save(pseudonym: String, verifyKey: Data, signKey: Data, encKey: Data, decKey: Data) throws {
        self._pseudonym = pseudonym
        self._verifyKey = verifyKey
        self._signKey = signKey
        self._encKey = encKey
        self._decKey = decKey
        self._previousDecKey = nil
        self.isRegistered = true
    }

    func rotate(verifyKey: Data, signKey: Data, encKey: Data, decKey: Data) throws {
        self._previousDecKey = _decKey
        self._verifyKey = verifyKey
        self._signKey = signKey
        self._encKey = encKey
        self._decKey = decKey
    }

    /// Leaves the public keys where they are and swaps the private halves for another identity's.
    func replacePrivateKeys(with other: RestorableIdentityStore) {
        _signKey = other._signKey
        _decKey = other._decKey
    }

    func signKey() throws -> Data {
        if let privateKeyFailure { throw privateKeyFailure }
        return _signKey
    }

    func decKey() throws -> Data {
        if let privateKeyFailure { throw privateKeyFailure }
        return _decKey
    }

    func previousDecKey() -> Data? { _previousDecKey }
}

private func registered() throws -> (IdentityService, RestorableIdentityStore) {
    let store = RestorableIdentityStore()
    let svc = IdentityService(identityStore: store)
    try svc.register(pseudonym: "test")
    return (svc, store)
}

@Test func aDeviceThatJustRegisteredIsIntact() throws {
    let (svc, _) = try registered()
    #expect(svc.integrity == .intact)
}

@Test func anUnregisteredDeviceIsIntactHavingNothingToHaveLost() {
    let svc = IdentityService(identityStore: RestorableIdentityStore())
    #expect(svc.integrity == .intact)
}

@Test func aRotationLeavesTheIdentityIntact() throws {
    let (svc, _) = try registered()
    try svc.activateKeyPair(svc.generateNewKeyPair())
    #expect(svc.integrity == .intact)
}

// The restore case: app storage came across, key storage did not.
@Test func privateKeysThatNoLongerReadAreKeysLost() throws {
    let (svc, store) = try registered()
    store.privateKeyFailure = AuthError.keychainLoad(itemNotFound)
    #expect(svc.integrity == .keysLost)
}

// Android stores the public keys in the clear beside the wrapped private halves, so they come back
// intact and the device advertises keys it cannot use. Modelled here because the vocabulary and the
// probe are shared.
@Test func publicKeysThatOutliveTheirPrivateHalvesAreKeysLost() throws {
    let (svc, store) = try registered()
    let (_, someoneElse) = try registered()
    store.replacePrivateKeys(with: someoneElse)
    #expect(svc.integrity == .keysLost)
}

// A locked device must never be mistaken for an emptied one — keysLost is what offers to mint a
// replacement identity over the top.
@Test func keyStorageThatIsMerelyLockedIsUnreadableNotLost() throws {
    let (svc, store) = try registered()
    store.privateKeyFailure = AuthError.identityStorageUnavailable(interactionNotAllowed)
    #expect(svc.integrity == .unreadable)
}

// Locked storage hides the public keys too, and they are optional — so the probe has to read the
// private halves first. Reading the public ones first would call this device emptied and offer it a
// replacement identity over a working one.
@Test func lockedStorageIsUnreadableEvenWhenThePublicKeysAreHiddenAsWell() throws {
    let (svc, store) = try registered()
    store.privateKeyFailure = AuthError.identityStorageUnavailable(interactionNotAllowed)
    store.publicKeysReadable = false
    #expect(svc.integrity == .unreadable)
}

@Test func publicKeysThatAreSimplyGoneAreKeysLost() throws {
    let (svc, store) = try registered()
    store.publicKeysReadable = false
    #expect(svc.integrity == .keysLost)
}

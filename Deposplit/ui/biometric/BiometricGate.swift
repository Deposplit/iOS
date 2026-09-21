import Foundation
import LocalAuthentication

/// Mirrors Android's `ui/biometric/BiometricGate.kt` shape so both platforms read the same way —
/// the passcode fallback included. Android allows `BIOMETRIC_STRONG or DEVICE_CREDENTIAL`, and
/// `.deviceOwnerAuthentication` is its iOS counterpart: the system offers the face or the finger
/// first and falls back to the device passcode, so an owner whose Face ID is off, or whose face is
/// not recognised, can still reach their own secret. Biometrics-only would lock them out of it.
enum AuthAvailability {
    case available
    /// Neither a biometric nor a passcode is set up, so there is nothing to authenticate against —
    /// the one remaining state worth explaining. There is no *no sensor* case any more: a phone
    /// without one authenticates by passcode like any other.
    case noneEnrolled
    case unavailable(String)
}

enum AuthResult {
    case succeeded
    case failed(String)
}

/// Android's `SKIP_BIOMETRIC`, in the form iOS has for it. A Simulator with no enrolled face
/// usually has no passcode to fall back on either, which leaves the reconstruct path unreachable
/// there.
/// Read through `UserDefaults`, which folds launch arguments in on its own, so it can be set in
/// Edit Scheme → Run → Arguments as `-skipBiometric YES` — that scheme is shared, so the edit is
/// for running, never for committing — or, without touching the scheme at all, with
/// `xcrun simctl spawn booted defaults write com.deposplit.Deposplit skipBiometric -bool YES`.
/// `#if DEBUG` keeps it out of a release build the way Android hard-codes `false` in its release
/// build type: the bypass cannot ship even if somebody sets the key on a shipped app.
var skipBiometric: Bool {
    #if DEBUG
    return UserDefaults.standard.bool(forKey: "skipBiometric")
    #else
    return false
    #endif
}

func biometricAvailability() -> AuthAvailability {
    if skipBiometric { return .available }
    let context = LAContext()
    var error: NSError?
    if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
        return .available
    }
    switch LAError.Code(rawValue: error?.code ?? 0) {
    case .passcodeNotSet:
        return .noneEnrolled
    default:
        return .unavailable(error?.localizedDescription ?? String(localized: "Authentication is currently unavailable."))
    }
}

func authenticate(reason: String) async -> AuthResult {
    if skipBiometric { return .succeeded }
    let context = LAContext()
    do {
        let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        return success ? .succeeded : .failed(String(localized: "Authentication failed."))
    } catch {
        return .failed(error.localizedDescription)
    }
}

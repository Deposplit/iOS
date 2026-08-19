import Foundation
import LocalAuthentication

/// Mirrors Android's `ui/biometric/BiometricGate.kt` shape so both platforms read the same way.
enum AuthAvailability {
    case available
    case noneEnrolled
    case noHardware
    case unavailable(String)
}

enum AuthResult {
    case succeeded
    case failed(String)
}

func biometricAvailability() -> AuthAvailability {
    let context = LAContext()
    var error: NSError?
    if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
        return .available
    }
    switch LAError.Code(rawValue: error?.code ?? 0) {
    case .biometryNotEnrolled:
        return .noneEnrolled
    case .biometryNotAvailable:
        return .noHardware
    default:
        return .unavailable(error?.localizedDescription ?? String(localized: "Biometric authentication is currently unavailable."))
    }
}

func authenticate(reason: String) async -> AuthResult {
    let context = LAContext()
    do {
        let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        return success ? .succeeded : .failed(String(localized: "Authentication failed."))
    } catch {
        return .failed(error.localizedDescription)
    }
}

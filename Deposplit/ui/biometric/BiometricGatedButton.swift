import SwiftUI

/// Wraps a reconstruct action behind Face ID/Touch ID — shared by `SecretDetailView` and
/// `RepairView` so both reconstruct call sites gate identically. When biometrics are unavailable it
/// says which of the three reasons applies, in place of the button: what cannot work is never left
/// standing with nothing behind it. Mirrors Android's `BiometricGate.kt`-driven messaging.
struct BiometricGatedButton: View {
    let label: LocalizedStringKey
    let reason: String
    var isDisabled: Bool = false
    let onAuthenticated: () async -> Void

    @State private var availability: AuthAvailability = .available
    @State private var isAuthenticating = false

    var body: some View {
        Group {
            switch availability {
            case .available:
                Button {
                    Task {
                        isAuthenticating = true
                        let result = await authenticate(reason: reason)
                        isAuthenticating = false
                        if case .succeeded = result {
                            await onAuthenticated()
                        }
                    }
                } label: {
                    if isAuthenticating {
                        ProgressView()
                    } else {
                        Text(label)
                    }
                }
                .disabled(isDisabled || isAuthenticating)
            case .noneEnrolled:
                Text("Enrol a biometric (Face ID or Touch ID) in device settings to reconstruct the secret.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .noHardware:
                Text("This device has no biometric sensor — reconstruction is disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unavailable:
                Text("Biometric authentication is currently unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { availability = biometricAvailability() }
    }
}

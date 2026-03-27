# iOS — Claude Code guidance

Platform-specific guidance for the `iOS/` repository. Cross-project context lives in `deposplit.com/CLAUDE.md` (loaded automatically when launching Claude from the workspace root via the `@`-import in `Deposplit/CLAUDE.md`).

## Toolchain

- Xcode 26+, Swift 6
- iOS 26+ deployment target (Apple's unified versioning, introduced 2025)
- SwiftUI (no UIKit, no storyboards)
- Swift Testing framework (not XCTest) — already in use in `ShamirSecretSharingTests.swift`

## Project structure

```
iOS/
├── Deposplit.xcodeproj/
├── Deposplit/                        ← app target sources
│   ├── DeposplitApp.swift            @main entry point
│   ├── ShamirSecretSharing.swift     SSS library (part of app target)
│   ├── auth/
│   │   ├── AuthPort.swift            Domain port protocol + RegistrationFlow enum
│   │   ├── DeposplitAuthAdapter.swift  Infrastructure adapter (deposplit.com API + libsodium keypair)
│   │   └── SignInViewModel.swift
│   └── ui/
│       ├── SignInView.swift
│       └── HomeView.swift            placeholder post-registration screen
└── DeposplitTests/                   ← unit test target
    └── ShamirSecretSharingTests.swift
```

## Build & test

Tests run via Xcode (Product → Test) or from the command line:

```bash
# from iOS/ — requires Xcode command-line tools
xcodebuild test \
  -project Deposplit.xcodeproj \
  -scheme Deposplit \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Key decisions to preserve

- **iOS 26+ deployment target** — Xcode 26 default; `@Observable`, `NavigationStack`, and all modern SwiftUI APIs are available. Do not lower without revisiting these dependencies.
- **All UI in SwiftUI** — no UIKit, no storyboards.
- **Registration is keypair-first** (libsodium X25519) — no OIDC, no password, no email. See `deposplit.com/CLAUDE.md` for rationale.
- **Private key storage**: X25519 private key lives in the iOS Keychain with Secure Enclave backing where available. App code never handles raw key material.
- **SSS is not a separate Swift Package**: `ShamirSecretSharing.swift` is compiled directly into the app target. Tests use `@testable import Deposplit` (not `@testable import ShamirSecretSharing`).
- **Use `@Observable`** (not `ObservableObject` / `@Published`) for view models — iOS 17+ only, consistent with the deployment target.
- **Navigation uses `NavigationStack`** (not the deprecated `NavigationView`).

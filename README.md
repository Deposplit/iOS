# Deposplit — iOS

The iOS app, plus the Swift port of Shamir's Secret Sharing.

Deposplit splits a secret into *n* shares, gives each to a person you choose, and
reconstructs it from any *k*. Fewer than *k* shares reveal nothing. All cryptography happens
on the device; the relay only stores and forwards bytes it cannot read.

**Design documentation lives in the hub repository** and covers all three platforms:

- [Architecture](https://github.com/Deposplit/deposplit.com/blob/main/docs/architecture.md)
- [Protocol](https://github.com/Deposplit/deposplit.com/blob/main/docs/protocol.md)
- [Security](https://github.com/Deposplit/deposplit.com/blob/main/docs/security.md)
- [Trust model](https://github.com/Deposplit/deposplit.com/blob/main/docs/trust-model.md)
- [Manual testing](https://github.com/Deposplit/deposplit.com/blob/main/docs/testing.md)

This README covers only what is specific to building and running the iOS app. iOS-specific
guidance for Claude Code is in [CLAUDE.md](CLAUDE.md).

## Requirements

- **Xcode 26 or later**, Swift 6
- Deployment target **iOS 26.4** — set as `IPHONEOS_DEPLOYMENT_TARGET`; do not lower it
- macOS, for anything involving the app target or a simulator

## Layout

Two pieces, deliberately separated:

| Path | What |
|---|---|
| `hexagon/` | A local Swift package — the domain. No `UIKit`, `SwiftUI`, `Security` or `URLSession`. |
| `Deposplit/` | The app target — adapters and SwiftUI views. |
| `Deposplit.xcodeproj` | The project. `Package.swift` is in `hexagon/`, not at the repo root. |

The package declares **no external dependencies**. The boundary is enforced by the compiler:
because `hexagon` has no dependency on the frameworks above, an accidental import fails to
build rather than quietly eroding the architecture.

**`hexagon/Sources/`** — `driving_ports/` (`Identity`, `ContactManagement`,
`ShareManagement`, `CatalogManagement`), `driving_adapters/` (the services implementing them,
plus `ShareEncryption`), `driven_ports/` (ten interfaces: `IdentityStore`,
`ContactRepository`, `ShareRepository`, `ShareMetadataRepository`, `SecretRepository`,
`RetainedDepositRepository`, `KeyConflictRepository`, `ShareRelay`, `ShareRelayResolver`,
`RelaySettings`), `value_objects/`, and `shamir/ShamirSecretSharing.swift`.

**`Deposplit/`** — `api/` (relay client, resolver, defaults), `auth/`
(`KeychainIdentityStore`), `contacts/` and `shares/` (JSON-file repositories), `settings/`,
and `ui/` split by screen: `home`, `contacts`, `deposit`, `sharedetail`, `repair`, `qr`,
`settings`, `biometric`, `reconstruction`.

The app target uses `PBXFileSystemSynchronizedRootGroup`, so any `.swift` file placed under
`Deposplit/` is compiled automatically — adding a file needs no `project.pbxproj` edit.

## Build and test

```bash
# from iOS/hexagon/ — no simulator needed, this is what CI runs
swift build
swift test                                  # 110 tests
swift test --filter ShamirSecretSharingTests

# from iOS/ — the app target
xcodebuild build -project Deposplit.xcodeproj -scheme Deposplit \
  -destination 'generic/platform=iOS'

xcodebuild test -project Deposplit.xcodeproj -scheme Deposplit \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Tests use the **Swift Testing** framework (`@Test`), not XCTest. All of them live in
`hexagon/Tests/`; there is no app-target test directory.

> `xcodebuild test` currently fails on this project's development machine with a
> code-signing error on an unsigned test dylib — a machine-level issue, unrelated to app
> code. `xcodebuild build` passes, and the hexagon package's own suite covers the domain.

> On Windows, Swift writes to the Windows Console API, so output is not captured by Git
> Bash. Run `swift test` from PowerShell, Windows Terminal or VS Code.

## Pointing at a local relay

The relay URL is **not** a compile-time switch. `RelayDefaults.fallbackBaseURL` supplies a
single fixed fallback (`https://api.deposplit.com`), and the app resolves its actual default
at runtime through `RelaySettings`, backed by `UserDefaults`.

Start a relay from `deposplit.com/`:

```bash
sbt run -Dconfig.file=conf/localhost.conf
```

Then set the default relay in the app's **Settings** screen:

- `http://localhost:9000` on the Simulator, which shares the host Mac's network stack — no
  App Transport Security exception needed, unlike the Android emulator's `10.0.2.2` alias.
- `http://<your-Mac-LAN-IP>:9000` on a physical device. Also add that address to
  `play.filters.hosts.allowed` in `conf/localhost.conf`.

A contact may additionally carry its own `relayBaseUrl` override, which takes precedence for
that contact's traffic — see the architecture doc on Bring Your Own Relay.

## Biometrics in the Simulator

There is deliberately **no** build flag to bypass the biometric gate, unlike Android's
`SKIP_BIOMETRIC`. The Simulator provides enrollment natively: **Features → Face ID → Enrolled**,
then **Features → Face ID → Matching Face** to satisfy a prompt. A Simulator with no
enrolment shows the same unavailable state a real device would.

## Localisation

English and German, in `Deposplit/Localizable.xcstrings`. Both must be kept in sync.

## Continuous integration

`.github/workflows/test.yml` runs `swift test` against the `hexagon` package on macOS, on
every push and on pull requests targeting `main`. The app target is not built in CI, because
that needs a simulator. Dependabot updates pinned action SHAs weekly.

## Licence

MIT. Copyright © 2026 [Squeng AG](https://www.squeng.com).

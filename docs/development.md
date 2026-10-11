# Development

## Requirements

- macOS 27, Xcode 27 (Swift 6.4)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), only when changing `App/project.yml`

If `xcode-select -p` points to the Command Line Tools, either run `sudo xcode-select -s /Applications/Xcode.app` or put `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in front of each command below.

## Repository layout

```
Package.swift            AddonKit library, addonctl CLI, AddonKitTests
Sources/AddonKit/        core library (docs/core.md)
Sources/addonctl/        command-line tool (docs/cli.md)
Tests/AddonKitTests/     Swift Testing suites; Fixtures/ holds recorded GitHub JSON, a catalogue CSV, zips
App/project.yml          XcodeGen spec for the app (docs/app.md)
App/ForeverAddons/       SwiftUI app
App/ForeverAddonsTests/  app unit tests
docs/                    all documentation
```

## Build and test

| Task | Command |
|---|---|
| Core + CLI tests | `swift test` |
| Live GitHub tests | `ADDONS_LIVE_TESTS=1 swift test` |
| CLI | `swift run addonctl --help` |
| App build | `xcodebuild -project App/ForeverAddons.xcodeproj -scheme ForeverAddons -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData build` |
| App tests | the same command with `test` instead of `build` |
| Regenerate Xcode project | `cd App && xcodegen generate` (commit the result) |

Or open `App/ForeverAddons.xcodeproj` in Xcode and press ⌘R.

## Testing without touching your real setup

- **Unit tests never touch real folders.** Directories are injected (`AppDirectories(root:)` on a temp folder), HTTP goes through `StubHTTPClient`, and downloads through `StubDownloadTransport`.
- **Manual runs:** set `ADDONS_DATA_DIR=<temp folder>`, which works for both the app and the CLI. Then add a fake installation such as `<tmp>/World of Warcraft/_classic_beta_/Interface/AddOns`.
- **CLI install offer:** the app's first-launch offer only appears with real data. Reset it with `defaults delete com.andrewmiotke.ForeverAddons didOfferCommandLineTool`.

## Conventions

- **Language settings:** Swift 6 language mode with strict concurrency. The package also enables `NonisolatedNonsendingByDefault` and `InferIsolatedConformances`. The app target makes code run on the main actor by default, so helpers that run elsewhere need `nonisolated`.
- **Shared state:** use actors or `Mutex`, not locks or `@unchecked Sendable`.
- **Tests:** use Swift Testing (`@Test`, `#expect`), not XCTest.
- **Xcode project:** edit `App/project.yml`, never `project.pbxproj` by hand.
- **Docs:** all documentation lives in `docs/`, one file per component. Update the relevant doc in the same commit as the change.

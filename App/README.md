# ForeverAddons (macOS app)

SwiftUI app for the AddonKit package in the repo root (see `DESIGN.md` §8).

## Project

`ForeverAddons.xcodeproj` is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Edit `project.yml`, not the project, then regenerate:

```sh
brew install xcodegen   # once
cd App && xcodegen generate
```

New files under `App/ForeverAddons/` are picked up on regeneration.

## Build & run

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project App/ForeverAddons.xcodeproj -scheme ForeverAddons \
  -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

Or open the project in Xcode and run the `ForeverAddons` scheme (signs ad-hoc, "Sign to Run Locally").

## Mock data

Until `AddonManager` exists, the app runs on `MockAddonManager` (`ForeverAddons/Mock/`). The switch is
one line in `ForeverAddonsApp.swift` (`// TODO: replace with AddonManager()`). Previews always use the mock.

## Layout

- `Models/` — `AppModel` (root, installations, selection, banner) and `InstallationModel` (per-installation
  add-ons, update state, row progress/errors, search).
- `Views/` — `ContentView` (split view + inspector), `InstalledView`, `BrowseView`, `AddonInspectorView`,
  `AdoptSheet`, `SettingsView`, shared `Components`.
- `Support/` — `KeychainStore` (GitHub token; Foundation + Security only, meant to move into AddonKit), small helpers.
- `Resources/Categories.json` — Browse category chips.

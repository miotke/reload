# ForeverAddons (macOS app)

SwiftUI app for the AddonKit package in the repo root (see `DESIGN.md` §8). It bundles the
`addonctl` command-line tool (§9.5).

## Project

`ForeverAddons.xcodeproj` is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Edit `project.yml`, not the project, then regenerate and commit the result:

```sh
brew install xcodegen   # once
cd App && xcodegen generate
```

New files under `App/ForeverAddons/` (and `../Sources/addonctl/`) are picked up on regeneration.

Targets:

- `ForeverAddons` — the app. Depends on the `AddonKit` package product and embeds `addonctl`.
- `addonctl` — command-line tool compiled from `../Sources/addonctl` (the whole folder) against
  `AddonKit` and `ArgumentParser` (swift-argument-parser, pinned to 1.5.0 like `Package.swift`).
  It's copied into `ForeverAddons.app/Contents/Helpers/addonctl` and code-signed with the app.
  The entry point is an `@main` type, so the target builds with `-parse-as-library`.
- `ForeverAddonsTests` — unit tests for app helpers (`CLIInstaller`, `DirectoryWatcher`). Not hosted:
  the sources under test are compiled into the test bundle, so tests never launch the app.

## Build, test & run

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project App/ForeverAddons.xcodeproj -scheme ForeverAddons \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData build   # or: test
```

Or open the project in Xcode and run the `ForeverAddons` scheme (signs ad-hoc, "Sign to Run Locally").

The bundled tool works straight from the build:

```sh
build/DerivedData/Build/Products/Debug/ForeverAddons.app/Contents/Helpers/addonctl --help
```

## Data

By default the app uses the real `AddonManager`: your WoW installations and the shared store in
`~/Library/Application Support/com.andrewmiotke.ForeverAddons` (the same one `addonctl` uses).

- **Sandboxed data:** set `ADDONS_DATA_DIR=<dir>`, as for `addonctl`. The store and caches live under
  `<dir>` and installation auto-detection is off, so only folders you add are touched. `open` doesn't
  pass environment variables; run the binary directly:

  ```sh
  ADDONS_DATA_DIR=$(mktemp -d) build/DerivedData/Build/Products/Debug/ForeverAddons.app/Contents/MacOS/ForeverAddons
  ```

The first-launch offer to install `addonctl` only appears on real data.

## Live updates from `addonctl`

The app watches the store folder (`InstallStore.storeDirectory`) with a `DispatchSource` and reloads,
debounced, when it changes, so add-ons installed or updated from the terminal show up immediately.
It also reloads whenever the app becomes active.

## Command-line tool install

On first launch (once, remembered in user defaults as `didOfferCommandLineTool`) the app offers to
install `addonctl`, unless it's already installed. **Install** creates a symlink
`/usr/local/bin/addonctl` → `<app>/Contents/Helpers/addonctl`, so updating the app updates the tool.
That needs admin rights, so the link is created by `do shell script … with administrator privileges`
(the standard password prompt). Cancelling leaves things as they were; Settings → Command-Line Tool
shows the status (not installed / installed / points to another copy of the app → Repair) with
Install and Uninstall. Uninstall only removes a link that points into a `ForeverAddons.app` bundle.

The logic lives in `Support/CLIInstaller.swift` with the privileged runner injectable for tests.
In Debug builds run from Xcode the helper lives in DerivedData, so the link points there.

To reset the first-launch offer: `defaults delete com.andrewmiotke.ForeverAddons didOfferCommandLineTool`.

## Layout

- `Models/` — `AppModel` (root: manager, installations, selection, banner, store watcher),
  `InstallationModel` (per-installation add-ons, update state, row progress/errors, search, browse) and
  `CommandLineToolModel` (CLI install state).
- `Views/` — `ContentView` (split view, inspector, empty state), `InstalledView`, `BrowseView`,
  `AddonInspectorView`, `AdoptSheet`, `SettingsView`, `CommandLineToolViews`, shared `Components`.
- `Support/` — `AppEnvironment` (standard or `ADDONS_DATA_DIR` wiring), `DirectoryWatcher`, `CLIInstaller`,
  small helpers. The Keychain wrapper lives in AddonKit (`KeychainStore`).

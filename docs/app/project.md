# App project

How the Xcode project is generated, its targets, the embedded CLI, where app data lives, and the app's source layout.

Build and test commands are in [development.md](../development.md).

## XcodeGen

`App/ForeverAddons.xcodeproj` is generated from `App/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). Edit `project.yml`, never `project.pbxproj`, then regenerate and commit the result:

```sh
brew install xcodegen   # once
cd App && xcodegen generate
```

New files under `App/ForeverAddons/` (and `Sources/addonctl/`) are picked up on regeneration.

## Targets

| Target | What it is |
|---|---|
| `ForeverAddons` | The app. Depends on the `AddonKit` package product and embeds `addonctl`. Default actor isolation `MainActor` |
| `addonctl` | The CLI, compiled from `../Sources/addonctl` (the whole folder) against `AddonKit` and `ArgumentParser` (swift-argument-parser, pinned to 1.5.0 like `Package.swift`). Built with `-parse-as-library` because the entry point is an `@main` type. Default isolation `nonisolated`, matching the package |
| `ForeverAddonsTests` | Unit tests for app helpers (`CLIInstaller`, `DirectoryWatcher`, `DayLabel`, `ScreenshotFilter`, table rows and sorting, `MarkdownParser`). Links `AddonKit`. Not hosted: the sources under test are compiled into the test bundle, so tests never launch the app |

The app is signed "Sign to Run Locally", so no Apple developer account is needed.

## Embedded CLI

- `addonctl` is copied into `ForeverAddons.app/Contents/Helpers/addonctl` and code-signed with the app.
- It works straight from the build:

  ```sh
  build/DerivedData/Build/Products/Debug/ForeverAddons.app/Contents/Helpers/addonctl --help
  ```

- Putting it on the `PATH`: [cli-install.md](cli-install.md). Why it's bundled: [decision 0006](../decisions/0006-bundled-cli-install.md).

## Data

By default the app uses the real `AddonManager`: your WoW installations and the shared store in `~/Library/Application Support/com.andrewmiotke.ForeverAddons`, the same one `addonctl` uses ([data-storage.md](../architecture/data-storage.md)). There's no mock data ([decision 0007](../decisions/0007-real-data-only.md)).

### `ADDONS_DATA_DIR`

Set `ADDONS_DATA_DIR=<dir>`, as for `addonctl`. The store and caches live under `<dir>` and installation auto-detection is off, so only folders you add are touched.

`open` doesn't pass environment variables, so run the binary directly:

```sh
ADDONS_DATA_DIR=$(mktemp -d) build/DerivedData/Build/Products/Debug/ForeverAddons.app/Contents/MacOS/ForeverAddons
```

In Xcode, set it under Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments. `AppEnvironment` does the wiring.

With sandboxed data, the first-launch `addonctl` offer doesn't appear, and the seeding flag isn't stored ([first-launch.md](first-launch.md)).

## Source layout

| Folder | Contents |
|---|---|
| `App/ForeverAddons/Models/` | `AppModel` (root: manager, installations, selections, banner, store watcher, seeding, auto refresh), `InstallationModel` (per-installation add-ons, update state, table rows, `RowState`s, `RefreshStatus`, search, browse, details), `CommandLineToolModel` (CLI install state) |
| `App/ForeverAddons/Views/` | `ContentView` (split view, sidebar with refresh progress, `InspectorSplit`), `InstalledView`, `BrowseView`, `AddonInspectorView`, `ScreenshotViews`, `MarkdownView`, `SeedingSheet`, `AdoptSheet`, `SettingsView`, `CommandLineToolViews`, shared `Components` |
| `App/ForeverAddons/Support/` | `AppEnvironment` (standard or `ADDONS_DATA_DIR` wiring), `DirectoryWatcher`, `CLIInstaller`, `TableSorting` + `TableRows`, `MarkdownBlocks`, `AddonFormatting` (`DayLabel`, `ScreenshotFilter`), `ScreenshotLoader`, small helpers |
| `App/ForeverAddonsTests/` | App unit tests |

The Keychain wrapper lives in AddonKit (`KeychainStore`), shared with the CLI.

## Settings

| Setting | Key / storage |
|---|---|
| GitHub token | Keychain (never in the JSON store) |
| Default channel | `defaultChannel` |
| Check for updates automatically | `checkForUpdatesOnLaunch` |
| Show update count in the menu bar | `showMenuBarExtra` |
| Command-Line Tool | [cli-install.md](cli-install.md) |

# App project

How the Xcode project is generated, its targets, the embedded CLI, where app data lives, and where each app file's code lives.

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
| `ForeverAddonsTests` | Unit tests for app helpers (`CLIInstaller`, `DirectoryWatcher`, `DayLabel`, table rows and sorting, `MarkdownParser`, `ScreenshotLoader` over a stub `URLProtocol`, the installation's models over a temp-folder `AddonManager`), `EnvironmentUsageTests` for [decision 0015](../decisions/0015-environment-only-at-scene-roots.md), `ArchitectureTests` for the core/UI boundary, and `SnapshotTests` ([development.md](../development.md#snapshots)). Links `AddonKit`. Not hosted: every app source but `ForeverAddonsApp.swift` is compiled into the test bundle, so tests never launch the app |

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

Set `ADDONS_DATA_DIR=<dir>`, as for `addonctl`. The store and caches (the screenshot cache included) live under `<dir>` and installation auto-detection is off, so only folders you add are touched.

`open` doesn't pass environment variables, so run the binary directly:

```sh
ADDONS_DATA_DIR=$(mktemp -d) build/DerivedData/Build/Products/Debug/ForeverAddons.app/Contents/MacOS/ForeverAddons
```

In Xcode, set it under Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments. `AppEnvironment` does the wiring.

With sandboxed data, the first-launch `addonctl` offer doesn't appear, and the seeding flag isn't stored ([first-launch.md](first-launch.md)).

## Where things live

Every Swift file of the app target, by responsibility. Update it in the same commit as any file you add, move, split or delete. How the models fit together: [layout.md](layout.md#models).

| Responsibility | File |
|---|---|
| App entry point, scenes, menu commands, menu bar extra | `App/ForeverAddons/ForeverAddonsApp.swift` |
| Wiring the manager: standard or `ADDONS_DATA_DIR` (the only file that names `AddonManager`) | `App/ForeverAddons/Support/AppEnvironment.swift` |
| Root model: installations, tab, search text, banner, store watcher, seeding, auto refresh | `App/ForeverAddons/Models/AppModel.swift` |
| One installation's models, wired together | `App/ForeverAddons/Models/InstallationModel.swift` |
| Add-ons, update states, Installed rows (sort, filter, sections), install action | `App/ForeverAddons/Models/InstalledModel.swift` |
| Search stream, home lists, Browse rows (sort, family filter), visible-row checks | `App/ForeverAddons/Models/BrowseModel.swift` |
| Live Browse patches from `metadataChanges()` | `App/ForeverAddons/Models/LiveMetadata.swift` |
| Inspector selection, details cache (LRU), release notes | `App/ForeverAddons/Models/InspectorModel.swift` |
| Refresh, update, Update All, install, pin, adopt, Move to Trash | `App/ForeverAddons/Models/UpdateQueue.swift` |
| Per-row progress and errors (`RowState`), refresh progress (`RefreshStatus`) | `App/ForeverAddons/Models/RowState.swift` |
| CLI install state (first-launch offer, Settings) | `App/ForeverAddons/Models/CommandLineToolModel.swift` |
| Window: split view, sidebar, toolbar, `InspectorSplit` | `App/ForeverAddons/Views/ContentView.swift` |
| Installed table and its cells and context menu | `App/ForeverAddons/Views/InstalledView.swift` |
| Browse table, filter bar, status bar and cells | `App/ForeverAddons/Views/BrowseView.swift` |
| Inspector pane, `AddonDetailView`, install actions, Retail build sheet | `App/ForeverAddons/Views/AddonInspectorView.swift` |
| Unmanaged folder inspector | `App/ForeverAddons/Views/UnmanagedInspector.swift` |
| Adopt sheet | `App/ForeverAddons/Views/AdoptSheet.swift` |
| Add-on window | `App/ForeverAddons/Views/AddonWindow.swift` |
| First-launch seeding sheet | `App/ForeverAddons/Views/SeedingSheet.swift` |
| Settings | `App/ForeverAddons/Views/SettingsView.swift` |
| CLI offer sheet and Settings section | `App/ForeverAddons/Views/CommandLineToolViews.swift` |
| Shared views: game bubbles and legend, activity, errors, refresh bar, banner | `App/ForeverAddons/Views/Components.swift` |
| README rendering | `App/ForeverAddons/Views/MarkdownView.swift` |
| Screenshot strip and viewer | `App/ForeverAddons/Views/ScreenshotViews.swift` |
| Pre-formatted Browse and Installed rows, `InstallAction`, live `patching` | `App/ForeverAddons/Support/TableRows.swift` |
| Sortable columns and the stored sort | `App/ForeverAddons/Support/TableSorting.swift` |
| `DayLabel`, `FetchLabel`, `GameBubblesModel`, filter labels, `RetailBuildOffer` | `App/ForeverAddons/Support/AddonFormatting.swift` |
| Adopt targets, removal requests, `AdoptForm`, adoption preview state | `App/ForeverAddons/Support/UnmanagedSupport.swift` |
| Settings keys, ⌘F search focus, small extensions, `RecentKeys` | `App/ForeverAddons/Support/AppSupport.swift` |
| Store folder watcher | `App/ForeverAddons/Support/DirectoryWatcher.swift` |
| Linking `addonctl` into `/usr/local/bin` | `App/ForeverAddons/Support/CLIInstaller.swift` |
| Markdown parsing into blocks (off the main actor) | `App/ForeverAddons/Support/MarkdownBlocks.swift` |
| Screenshot download, disk cache and thumbnail decoding | `App/ForeverAddons/Support/ScreenshotLoader.swift` |
| App unit and architecture tests | `App/ForeverAddonsTests/` |
| UI snapshots: fixtures, test-only manager, renderer | `App/ForeverAddonsTests/Snapshots/` |

The Keychain wrapper lives in AddonKit (`KeychainStore`), shared with the CLI.

## Settings

| Setting | Key / storage |
|---|---|
| GitHub token | Keychain (never in the JSON store) |
| Default channel | `defaultChannel` |
| Check for updates automatically | `checkForUpdatesOnLaunch` |
| Show update count in the menu bar | `showMenuBarExtra` |
| Command-Line Tool | [cli-install.md](cli-install.md) |

# App project

How the Xcode project is generated, its targets, the embedded CLI, where app data lives, and where each app file's code lives.

Build and test commands are in [development.md](../development.md).

## XcodeGen

`App/Reload.xcodeproj` is generated from `App/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). Edit `project.yml`, never `project.pbxproj`, then regenerate and commit the result:

```sh
brew install xcodegen   # once
cd App && xcodegen generate
```

New files under `App/Reload/` (and `Sources/reload/`) are picked up on regeneration.

## Targets

| Target | What it is |
|---|---|
| `Reload` | The app. Depends on the `AddonKit` package product and embeds `reload`. Default actor isolation `MainActor` |
| `reload` | The CLI, compiled from `../Sources/reload` (the whole folder) against `AddonKit` and `ArgumentParser` (swift-argument-parser, pinned to 1.5.0 like `Package.swift`). Built with `-parse-as-library` because the entry point is an `@main` type. Default isolation `nonisolated`, matching the package |
| `ReloadTests` | Unit tests for app helpers (`CLIInstaller`, `DirectoryWatcher`, `DayLabel`, table rows and sorting, `MarkdownParser`, `ScreenshotLoader` over a stub `URLProtocol`, the installation's models over a temp-folder `AddonManager`, sidebar sections and search scope), `EnvironmentUsageTests` for [decision 0015](../decisions/0015-environment-only-at-scene-roots.md), `ArchitectureTests` for the core/UI boundary, and `SnapshotTests` ([development.md](../development.md#snapshots)). Links `AddonKit`. Not hosted: every app source but `ReloadApp.swift` is compiled into the test bundle, so tests never launch the app |

The app is signed "Sign to Run Locally", so no Apple developer account is needed.

## Embedded CLI

- `reload` is copied into `Reload.app/Contents/Helpers/reload` and code-signed with the app.
- It works straight from the build:

  ```sh
  build/DerivedData/Build/Products/Debug/Reload.app/Contents/Helpers/reload --help
  ```

- Putting it on the `PATH`: [cli-install.md](cli-install.md). Why it's bundled: [decision 0006](../decisions/0006-bundled-cli-install.md).

## Data

By default the app uses the real `AddonManager`: your WoW installations and the shared store in `~/Library/Application Support/io.github.miotke.Reload`, the same one `reload` uses ([data-storage.md](../architecture/data-storage.md)). There's no mock data ([decision 0007](../decisions/0007-real-data-only.md)).

### `RELOAD_DATA_DIR`

Set `RELOAD_DATA_DIR=<dir>`, as for `reload`. The store and caches (the screenshot cache included) live under `<dir>` and installation auto-detection is off, so only folders you add are touched.

`open` doesn't pass environment variables, so run the binary directly:

```sh
RELOAD_DATA_DIR=$(mktemp -d) build/DerivedData/Build/Products/Debug/Reload.app/Contents/MacOS/Reload
```

In Xcode, set it under Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments. `AppEnvironment` does the wiring.

With sandboxed data, the first-launch `reload` offer doesn't appear, and the seeding flag isn't stored ([first-launch.md](first-launch.md)).

## Where things live

Every Swift file of the app target, by responsibility. Update it in the same commit as any file you add, move, split or delete. How the models fit together: [layout.md](layout.md#models).

| Responsibility | File |
|---|---|
| App entry point, scenes, menu commands, menu bar extra | `App/Reload/ReloadApp.swift` |
| Wiring the manager: standard or `RELOAD_DATA_DIR` (the only file that names `AddonManager`) | `App/Reload/Support/AppEnvironment.swift` |
| Root model: installations (and the remembered one), sidebar section, search text, banner, store watcher, seeding, auto refresh | `App/Reload/Models/AppModel.swift` |
| One installation's models, wired together | `App/Reload/Models/InstallationModel.swift` |
| Add-ons, update states, library rows (sort, filter, section) and section counts, install action | `App/Reload/Models/InstalledModel.swift` |
| Search stream, home lists, Browse rows (sort, family filter), visible-row checks | `App/Reload/Models/BrowseModel.swift` |
| Live Browse patches from `metadataChanges()` | `App/Reload/Models/LiveMetadata.swift` |
| Inspector selection, details cache (LRU), release notes | `App/Reload/Models/InspectorModel.swift` |
| Refresh, update, Update All, install, pin, adopt, Move to Trash | `App/Reload/Models/UpdateQueue.swift` |
| Per-row progress and errors (`RowState`), refresh progress (`RefreshStatus`) | `App/Reload/Models/RowState.swift` |
| CLI install state (first-launch offer, Settings) | `App/Reload/Models/CommandLineToolModel.swift` |
| Window: split view, the sidebar host (reads its progress and counts), detail per section, toolbar, search field and its scope, title menu wiring, `InspectorSplit` | `App/Reload/Views/ContentView.swift` |
| Sidebar (library sections with counts, Browse, categories, refresh bar) and the title menu's game picker | `App/Reload/Views/SidebarView.swift` |
| Library table (Installed, Updates, Unmanaged, Pinned), its cells, context menu, empty states and the Updates header | `App/Reload/Views/InstalledView.swift` |
| Browse table, filter bar, status bar and cells | `App/Reload/Views/BrowseView.swift` |
| Inspector pane, `AddonDetailView`, install actions, Retail build sheet | `App/Reload/Views/AddonInspectorView.swift` |
| Unmanaged folder inspector | `App/Reload/Views/UnmanagedInspector.swift` |
| Adopt sheet | `App/Reload/Views/AdoptSheet.swift` |
| Add-on window | `App/Reload/Views/AddonWindow.swift` |
| First-launch seeding sheet | `App/Reload/Views/SeedingSheet.swift` |
| Settings scene: tabs, General and Advanced tabs, `settingsTab()` sizing | `App/Reload/Views/SettingsView.swift` |
| Settings ▸ Appearance: appearance cards, app icon grid | `App/Reload/Views/AppearanceSettings.swift` |
| Settings ▸ GitHub: token field, token source, rate-limit rows | `App/Reload/Views/GitHubSettings.swift` |
| GitHub rate-limit status: reload loop and display formatting | `App/Reload/Models/GitHubStatusModel.swift` |
| CLI offer sheet, Settings ▸ Command Line tab and section | `App/Reload/Views/CommandLineToolViews.swift` |
| Shared views: game bubbles and legend, activity, errors, refresh bar, banner | `App/Reload/Views/Components.swift` |
| README rendering | `App/Reload/Views/MarkdownView.swift` |
| Screenshot strip and viewer | `App/Reload/Views/ScreenshotViews.swift` |
| Pre-formatted Browse and Installed rows, live `patching` | `App/Reload/Support/TableRows.swift` |
| Sortable columns and the stored sort | `App/Reload/Support/TableSorting.swift` |
| Sidebar sections (`LibrarySection`, `SidebarItem`), section filters, `LibraryCounts`, search prompt and Browse query per section | `App/Reload/Support/SidebarSections.swift` |
| `DayLabel`, `FetchLabel`, `GameBubblesModel`, filter labels, `UpdateOffer.label`, Retail build wording | `App/Reload/Support/AddonFormatting.swift` |
| Adopt targets, removal requests, `AdoptForm`, adoption preview state | `App/Reload/Support/UnmanagedSupport.swift` |
| Settings keys, appearance choice, ⌘F search focus, small extensions, `RecentKeys` | `App/Reload/Support/AppSupport.swift` |
| Settings tabs, app icon choice, first-launch reset, GitHub token source and model | `App/Reload/Support/SettingsSupport.swift` |
| Store folder watcher | `App/Reload/Support/DirectoryWatcher.swift` |
| Linking `reload` into `/usr/local/bin` | `App/Reload/Support/CLIInstaller.swift` |
| Markdown parsing into blocks (off the main actor) | `App/Reload/Support/MarkdownBlocks.swift` |
| Screenshot download, disk cache and thumbnail decoding | `App/Reload/Support/ScreenshotLoader.swift` |
| App unit and architecture tests | `App/ReloadTests/` |
| UI snapshots: fixtures, test-only manager, renderer | `App/ReloadTests/Snapshots/` |

The Keychain wrapper lives in AddonKit (`KeychainStore`), shared with the CLI.

## Settings

Tabs, keys and the app icon: [settings.md](settings.md).

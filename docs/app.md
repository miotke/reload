# App (ForeverAddons.app)

The SwiftUI app in `App/`, built on the AddonKit core ([core.md](core.md); original design in [design.md](design.md) §8). It bundles the `addonctl` command-line tool ([cli.md](cli.md)).

## Project

`App/ForeverAddons.xcodeproj` is generated from `App/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Edit `project.yml`, not the project, then regenerate and commit the result:

```sh
brew install xcodegen   # once
cd App && xcodegen generate
```

New files under `App/ForeverAddons/` (and `Sources/addonctl/`) are picked up on regeneration.

Targets:

- `ForeverAddons` — the app. Depends on the `AddonKit` package product and embeds `addonctl`.
- `addonctl` — command-line tool compiled from `../Sources/addonctl` (the whole folder) against
  `AddonKit` and `ArgumentParser` (swift-argument-parser, pinned to 1.5.0 like `Package.swift`).
  It's copied into `ForeverAddons.app/Contents/Helpers/addonctl` and code-signed with the app.
  The entry point is an `@main` type, so the target builds with `-parse-as-library`.
- `ForeverAddonsTests` — unit tests for app helpers (`CLIInstaller`, `DirectoryWatcher`, `DayLabel`,
  `ScreenshotFilter`, table rows and sorting, `MarkdownParser`). Links `AddonKit`. Not hosted:
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

## Window layout

```
┌───────────────┬──────────────────────────────────────────────────────────────┐
│               │ toolbar: [Installed|Browse]   ⟳  Update All  ▣  🔍 search    │
│ Installations ├───────────────────────────────────────┬──────────────────────┤
│               │ table (Installed or Browse)           │ inspector            │
│               │                                       │ (drag edge to resize)│
│ Add Install…  │                                       │                      │
│ ▓▓▓▓░░ msg    │                                       │                      │
└───────────────┴───────────────────────────────────────┴──────────────────────┘
```

- **Inspector placement.** The inspector is part of the detail column's content (a small custom
  split, `InspectorSplit` in `ContentView.swift`), not `.inspector`, so the toolbar and search field
  span the detail area and the inspector starts below them. Toggle it with the toolbar button or
  ⌥⌘I; drag its leading edge to resize (280–560 pt, remembered as `inspectorWidth`). Selecting a row
  in either tab opens it.
- **Installed table.** Columns: Name (repository beside it), Version (`1.2 → 1.3` when an update is
  available), Channel, Status (missing files / update / check failed / no Forever build / pinned / up
  to date / unmanaged), Installed, and an action column (Update/Retry, Adopt…, progress). Managed and
  unmanaged folders are separate sections, each sorted. Errors show as a red icon with the message
  in its tooltip and in the inspector.
- **Browse table.** Columns: Name (author and one-line summary under it), Forever (support badge),
  Stars, Updated, and an action column (Install / progress / Overwrite / Open). With an empty query a
  Popular / Recently Updated switch picks the list (one table rather than two sections, so sorting
  applies to whichever list you're looking at); category chips and **Forever only** run or filter
  the query as before. A status bar shows the count, "Searching…" / "Searching GitHub…" while the
  stream is open, and **Search GitHub for More Results**.
- **Sorting.** Click a header to sort, again to reverse. Dates and stars sort by value, versions
  numerically, Status by what needs attention; missing values sort last both ways. The sort is
  remembered per table (`installedSort`, `browseSort` in user defaults, e.g. `updated.desc`); column
  widths and visibility per window (`@SceneStorage`). Browse can return to the core's order
  (relevance, or stars/date for the home lists) with **Sort by Relevance** / **Default Order**.
- **Dates.** Installed, released and updated dates read "Today" or a short date ("Oct 9, 2026"),
  never "x seconds ago" (`DayLabel`).

## Inspector

For any selected add-on, installed or not, the inspector shows the header (name, author, summary,
Forever badge), Install / Update / Roll Back / Uninstall, then `details(for:in:)`: latest version
and date, stars, last update, license, topics, GitHub and homepage links, a screenshot strip, and
the README. Installed add-ons add the install's version, dates, channel, pin, folders and changelog.

- Details load 250 ms after the selection settles (arrow-keying through a table doesn't fetch every
  row) and are cancelled when the selection changes. Results are cached per add-on for the session;
  failures show inline with **Try Again**. The returned support status updates that row's badge.
- **Screenshots** are README images minus badges and SVGs, at most 6. Thumbnails load lazily as the
  strip scrolls through `ScreenshotLoader`: its own `URLSession` with a 32 MB / 200 MB `URLCache`,
  5 MB per image cap, ImageIO downsampling off the main actor, and an `NSCache` of decoded images.
  Clicking one opens a viewer sheet (← / → to step, Esc to close) that loads a larger version.
- **README** is parsed off the main actor by `MarkdownParser` (headings, paragraphs, lists, code,
  quotes, tables, rules; images, HTML tags and comments stripped) and rendered lazily by `MarkdownView`,
  with relative links resolved against the repository. Changelogs use the same renderer, cached.

## Network use

Search is local; the network is used on first launch, every 2 hours, and when you open, install or
update an add-on.

| Trigger | Call |
|---|---|
| First launch (no completed refresh: `lastRefresh(in:) == nil` and no `didSeedAddonDetails` flag) | `refresh(force: true)` behind the seeding sheet |
| Launch, app activation, every 2 h while running | `refresh(force: false)`; the core throttles it, so it's cheap |
| Check for Updates (⌘R, toolbar, menu bar extra) | `refresh(force: true)` |
| Selecting an add-on | `details(for:in:)` (debounced) and screenshot downloads |
| Install, update, rollback, adopt | as before; rollback just marks the add-on pinned, no re-check |
| **Search GitHub for More Results** | a live GitHub search; the core also falls back to one by itself when a 3+ character query has fewer than 3 local matches |

Automatic refreshes can be turned off in Settings (**Check for updates automatically**, key
`checkForUpdatesOnLaunch`). The 2-hour timer is one task, restarted when the selected installation
changes and skipped while a refresh is running. A refresh's `.finished` event carries the update
states, which replace the Installed statuses; during the support phase the Browse lists are re-read
at most every 2 s so badges fill in.

**First launch.** A sheet titled "Gathering Add-on Details" blocks the window with a determinate
progress bar, the current step and "n of m". It closes when the refresh finishes; after 3 seconds
**Continue in Background** lets you in while it keeps going. The `addonctl` offer appears after
the sheet closes. On sandboxed data (`ADDONS_DATA_DIR`) the flag isn't stored, so only
`lastRefresh` decides. To see the sheet again: `defaults delete com.andrewmiotke.ForeverAddons didSeedAddonDetails`.

**Sidebar progress.** While a refresh reports progress, a small bar and message sit under
**Add Installation…**. Throttled refreshes that finish at once never show it.

## Live updates from `addonctl`

The app watches the store folder (`InstallStore.storeDirectory`) with a `DispatchSource` and reloads,
debounced, when it changes, so add-ons installed or updated from the terminal show up immediately.
Store-watcher reloads only re-read the add-on list (never the network), and are skipped when the
folder's fingerprint (paths, sizes, modification dates) matches the last reload, which is what
happens after the app's own writes. It also reloads whenever the app becomes active.

## Performance notes

- Table rows (`BrowseRow`, `InstalledRow`) are flat, `Equatable`, pre-formatted values built and
  sorted in `InstallationModel` when the data, filter or sort changes, never in `body`.
- Per-row progress and errors live in one `@Observable RowState` per row, so a download tick
  re-renders only that row's cells and the inspector's action bar.
- Refresh progress lives in `RefreshStatus`, observed only by the sidebar bar and the seeding sheet.
- Reloads assign `addons` / `installations` only when the value changed.

## Command-line tool install

On first launch (once, remembered in user defaults as `didOfferCommandLineTool`) the app offers to
install `addonctl`, unless it's already installed. **Install** creates a symlink
`/usr/local/bin/addonctl` → `<app>/Contents/Helpers/addonctl`, so updating the app updates the tool.
That needs admin rights, so the link is created by `do shell script … with administrator privileges`
(the standard password prompt). Cancelling leaves things as they were; Settings → Command-Line Tool
shows the status (not installed / installed / points to another copy of the app → Repair) with
Install and Uninstall. Uninstall only removes a link that points into a `ForeverAddons.app` bundle.

The logic lives in `App/ForeverAddons/Support/CLIInstaller.swift` with the privileged runner injectable for tests.
In Debug builds run from Xcode the helper lives in DerivedData, so the link points there.

To reset the first-launch offer: `defaults delete com.andrewmiotke.ForeverAddons didOfferCommandLineTool`.

## Layout

- `App/ForeverAddons/Models/` — `AppModel` (root: manager, installations, selections, banner, store
  watcher, seeding, auto refresh), `InstallationModel` (per-installation add-ons, update state, table
  rows, `RowState`s, `RefreshStatus`, search, browse, details) and `CommandLineToolModel` (CLI install state).
- `App/ForeverAddons/Views/` — `ContentView` (split view, sidebar with refresh progress, `InspectorSplit`),
  `InstalledView`, `BrowseView`, `AddonInspectorView`, `ScreenshotViews`, `MarkdownView`, `SeedingSheet`,
  `AdoptSheet`, `SettingsView`, `CommandLineToolViews`, shared `Components`.
- `App/ForeverAddons/Support/` — `AppEnvironment` (standard or `ADDONS_DATA_DIR` wiring), `DirectoryWatcher`,
  `CLIInstaller`, `TableSorting` + `TableRows`, `MarkdownBlocks`, `AddonFormatting` (`DayLabel`,
  `ScreenshotFilter`), `ScreenshotLoader`, small helpers. The Keychain wrapper lives in AddonKit (`KeychainStore`).

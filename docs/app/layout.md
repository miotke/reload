# App layout

The main window (sidebar, toolbar, inspector placement, the Installed and Browse tables, sorting) and the separate add-on window.

Code: `App/ForeverAddons/Views/` (`ContentView`, `InstalledView`, `BrowseView`), `Models/`, `Support/TableRows.swift`, `Support/TableSorting.swift`. Why the inspector and tables work this way: [decision 0012](../decisions/0012-inspector-and-tables.md).

## Window

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

- **Sidebar:** installations, **Add Installation…**, and the [refresh progress bar](first-launch.md#sidebar-progress).
- **Toolbar:** tab picker, ⟳ Check for Updates (⌘R), Update All, inspector toggle, search field. ⌘F focuses search from any tab; on Installed it filters the list.
- **Menu bar extra** (optional, Settings): shows the update count.

## Flavor names

Labels follow the selected installation's game, `installation.flavor.displayName` (Forever, Retail, Classic Era, TBC Anniversary, Wrath Classic, Titan, Cata Classic, Mists Classic; see [flavors.md](../architecture/flavors.md#flavors)): the Games tooltips, the filter toggle's help, Installed status, the inspector, the adopt sheet and the seeding sheet. The Games column and the filter toggle's label follow the installation's game family.

Forever-specific on purpose: the app name, help text and the empty state that suggests adding `World of Warcraft/_classic_beta_`.

## Models

Each installation has one `InstallationModel`, which only owns and wires four feature models:

| Model | Owns |
|---|---|
| `InstalledModel` | add-ons, stored update states, the Installed rows (sort, filter, sections), `installAction(for:)` |
| `BrowseModel` | search stream, home lists, Browse rows (sort, family filter), visible-row checks; `LiveMetadata` patches its rows |
| `InspectorModel` | the selection in each tab, loaded details (the 20 most recent), release notes |
| `UpdateQueue` | refresh and its `RefreshStatus`, update, Update All, install, pin, adopt, and each row's `RowState` |

- Views take the model they need as a property: cells take `UpdateQueue`, `BrowseModel` or a pre-built row; tables take their tab's models. `AddonDetailView`, `InspectorPane` and `AddonWindow` combine all four, so they take `InstallationModel` and read its parts directly. There are no forwarding methods.
- The app reaches the core only through `AddonManaging`; `ArchitectureTests` fails on any app file but `AppEnvironment.swift` that names `AddonManager` or a core internal.
- Decisions the core will take over are isolated in helpers marked `TODO(core-ui)`.

## Inspector placement

- The inspector is part of the detail column's content (a small custom split, `InspectorSplit` in `ContentView.swift`), **not `.inspector`**. That way the toolbar and search field span the detail area and the inspector starts below them.
- Toggle it with the toolbar button or ⌥⌘I.
- Drag its leading edge to resize (280–560 pt, remembered as `inspectorWidth`).
- Selecting a row in either tab opens it. Contents: [details-and-screenshots.md](../features/details-and-screenshots.md).

## Installed table

| Column | Shows |
|---|---|
| Name | name, with the repository beside it |
| Version | `1.2 → 1.3` when an update is available (`→ Forever build` when it replaces a Retail build); **Retail build** beside it when that's the build in use |
| Channel | stable / prerelease |
| Status | missing files / update / check failed / no *<flavor>* build / pinned / up to date / unmanaged / not loaded by *<flavor>* |
| Installed | date |
| Action | Update / Retry, Adopt…, progress |

- Managed and unmanaged folders are separate sections, each sorted.
- **Unmanaged rows** show the title and version of the TOC the game loads for the flavor (`Questie`, `v12.0.4`), not the folder's base TOC, with the folder name beside it when it differs. Folders one release ships are one row, "Questie · 2 folders" ([data-storage.md](../architecture/data-storage.md#reconcile)). When no TOC is for the flavor, Status says **Not loaded by Forever**.
- **Context menus.** Managed: Update, Pin/Unpin, Open on GitHub, Show in Finder, **Uninstall…**. Unmanaged: Adopt…, Show in Finder, **Move to Trash…**. Both confirm through one dialog at the window root (`AppModel.pendingRemoval`), since a menu can't host it. The trash dialog lists every folder in the group.
- **Update** and **Update All** install the releases the last check found (`update(releases:in:)`), with no second check. With nothing available, Update All does nothing (an empty list used to mean "update everything", which was a bug).
- Errors show as a red icon with the message in its tooltip and in the inspector ([errors.md](../architecture/errors.md)).
- Action buttons in both tables (Install, Overwrite, Update/Retry, Adopt…) are bordered and small.

## Unmanaged folders: inspector and Adopt sheet

- **Inspector** (`UnmanagedInspector`): the loaded TOC's title, version, author, notes, interface and file name; "Loaded by / Not loaded by *<flavor>*"; the folders; **Adopt…** and **Move to Trash…**. With a suggestion, it shows the repo and the reason ("Matched CurseForge project 334372") and loads that repo's summary, screenshots and README through `details(for:in:)`, which spends no API quota.
- **Adopt sheet** (`AdoptSheet`, logic in `AdoptForm`):
  - The repository field is pre-filled with the best [candidate](../features/installing.md#adopting-unmanaged-folders) and a "Why" line; a **Suggestions** picker appears when there are several. The field stays editable (`owner/repo`, `github:` or a URL).
  - **Search GitHub…** runs one explicit live search (the 10-a-minute search quota) and lists results to pick. Nothing else in the sheet searches.
  - Choosing a repo (pre-fill, picker, search pick, Return or **Check Release**) runs `adoptionPreview`: the release version, the folders it **replaces** and **adds**, folders another add-on owns, and folders that stay unmanaged. Typing alone doesn't, so a half-typed name costs nothing.
  - **Adopt** is enabled for a valid ref, unless its preview found no *<flavor>* build ("This repository has no Forever build…") or a folder conflict. It installs the previewed release without resolving again.
  - **Move to Trash…** with its own confirmation, listing the folders.

## Installed state

Browse rows, the inspector and the add-on window all take an add-on's installed state from `InstalledModel.installAction(for:)`: the managed list keyed by lower-cased ref, plus the stored update state. They never read it from a `SearchResult` or `AddonDetails`, so `Cidan/BetterBags` found as `cidan/betterbags` still shows as installed. The inspector shows **Installed v0.5.14**, **Update to …** when an update is stored, and **Uninstall…**.

## Browse table

| Column | Shows |
|---|---|
| Name | author and a one-line summary under it |
| Games | [R F C bubbles](#games) |
| Stars | count; hidden by default, turn it on from the header's context menu |
| Last updated | date |
| Action | Install / progress / Overwrite / ✓ Installed / Update |

- With an empty query, a **Popular / Recently Updated** switch picks the list. It's one table rather than two sections, so sorting applies to whichever list you're looking at.
- Category chips run their saved query; the **Hide Classic-only** toggle ("Hide add-ons without a Retail build" on Retail, "…without a Classic build" on the classics; on by default, same `browseForeverOnly` key) filters both the home lists and search results by the [per-family rule](../features/search.md#hide-incompatible). Rows whose own game isn't confirmed are dimmed.
- Installed rows show a ✓ **Installed** label, or **Update** when one is stored. Double-click or Return opens the add-on window; the context menu has **Show in Installed**.
- **Visible-row checks.** About 1 s after scrolling stops, the rows on screen (unchecked ones first, up to 20) go to `checkVisible`, which skips fresh answers and spends no API quota ([refresh.md](../features/refresh.md#visible-row-checks)). Rows report themselves through the Name cell's `onAppear` / `onDisappear`: AppKit hosts cells only for rows on screen (plus a few around them), so this names the visible rows directly, where scroll-phase and geometry modifiers would only give offsets. Each change restarts the 1 s timer. A new query or an empty search cancels it; nothing runs while a refresh does. Answers patch rows live ([live-data.md](live-data.md)).
- A status bar shows the count, "Searching…" until the last update (or "Searching GitHub…" while the core reports a live search), and **Search GitHub for More Results**. "No results" appears only after the last update.
- Beside the count, the **legend** "R Retail · F Forever · C Classic" (`GameLegend`; letters only, with a tooltip, when the bar is narrow), and **Last fetched Oct 12, 7:18 AM** ("Today, 7:18 AM" for today, "Not fetched yet" before the first refresh), from `lastRefresh(in:)` and updated when a refresh finishes (`FetchLabel`). The ⟳ button next to it runs a forced refresh, like ⌘R; while one runs it's a small spinner and disabled.

## Games

Which games an add-on's latest release ships builds for, replacing the old single "Forever" verdict ([decision 0019](../decisions/0019-available-games-and-visible-row-checks.md)). One view, `GameBubbles`, in the Browse column, the inspector, the add-on window, the unmanaged inspector and the adopt sheet's search results.

```
 R  F  C     filled = this installation's family   tinted = present   outline = no build   —  not checked
```

- Three fixed-position capsules: **R** blue, **F** teal, **C** orange (system colours, so light and dark mode work). Present ones are tinted; the installation's own family is filled, with a bold letter; absent ones are a faint outline in the same slot, so columns line up.
- **Not checked** (no `release.json`, never checked): a dim "—", whose tooltip says why.
- Tooltips per bubble: "Classic: Era, TBC Anniversary, Wrath, Cata, Mists"; on Forever, R says "Retail build: may work on Forever, which lists it as out of date until you tick Load out of date AddOns"; "No Forever build".
- **Cheap cells.** `GameBubblesModel` is built with the row (`BrowseRow.games`), so the cell reads stored values and no environment.
- **Sorting:** own family present first, then the number of families; unchecked rows last. The column keeps the `support` sort key.
- **Inspector and add-on window:** the bubbles plus `GameAvailability.sentence`: "Has a Forever build", "Retail build only: may work on Forever; it will show as out of date", "Classic only: won't load on Forever", "Not checked yet". For a Retail-only add-on on Forever the action is **Install Retail Build…**, whose confirmation sheet explains *Load out of date AddOns* and installs with `allowFamilyFallback: true`. Installed add-ons show **Build: Retail build**, and **Update to Forever build** once one appears ([release-selection.md](../features/release-selection.md#retail-build-on-forever)).

## Sorting

- Click a header to sort, again to reverse.
- Dates and stars sort by value, versions numerically, Status by what needs attention. Missing values sort last both ways.
- The sort is remembered per table (`installedSort`, `browseSort` in user defaults, e.g. `updated.desc`). Column widths and visibility are remembered per window (`@SceneStorage`).
- Browse can return to the core's order (relevance, or stars/date for the home lists) with **Sort by Relevance** / **Default Order**.
- Rows are pre-formatted and sorted in `InstalledModel` and `BrowseModel`, never in `body` ([performance/guidelines.md](../performance/guidelines.md#tables-and-lists)).
- **Only scene roots read `@Environment(AppModel.self)`** (`ContentView`, `SettingsView`, `MenuBarContent`; `AddonWindow` gets it from the `App` as a property). Cells, context menus, `primaryAction` handlers, toolbars, sheets and the inspector get the model, row state or closures as plain properties. `EnvironmentUsageTests` enforces it. Why: [decision 0015](../decisions/0015-environment-only-at-scene-roots.md).

## Dates

Installed, released and updated dates read "Today" or a short date ("Oct 9, 2026"), never "x seconds ago" (`DayLabel`).

## Add-on window

- **Double-click or Return** on a Browse row or a managed Installed row opens the add-on in its own window. Both tables' context menus also have **Open in New Window**.
- It's a `WindowGroup(id: "addon", for: AddonWindowID)`; `AddonWindowID` holds the ref and the installation ID. Opening the same add-on again focuses its existing window.
- Default size 900×800, minimum 560×420.
- It reuses `AddonDetailView` (the inspector's content) in a `.window` style, with 320×200 thumbnails. Contents: [details-and-screenshots.md](../features/details-and-screenshots.md).

## Live updates

The tables follow database changes and install-store writes from the app and the CLI: [live-data.md](live-data.md).

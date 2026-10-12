# App layout

The window: sidebar, toolbar, inspector placement, the Installed and Browse tables, sorting, and live reloads from the CLI.

Code: `App/ForeverAddons/Views/` (`ContentView`, `InstalledView`, `BrowseView`), `Support/TableRows.swift`, `Support/TableSorting.swift`. Why the inspector and tables work this way: [decision 0012](../decisions/0012-inspector-and-tables.md).

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

## Inspector placement

- The inspector is part of the detail column's content (a small custom split, `InspectorSplit` in `ContentView.swift`), **not `.inspector`**. That way the toolbar and search field span the detail area and the inspector starts below them.
- Toggle it with the toolbar button or ⌥⌘I.
- Drag its leading edge to resize (280–560 pt, remembered as `inspectorWidth`).
- Selecting a row in either tab opens it. Contents: [details-and-screenshots.md](../features/details-and-screenshots.md).

## Installed table

| Column | Shows |
|---|---|
| Name | name, with the repository beside it |
| Version | `1.2 → 1.3` when an update is available |
| Channel | stable / prerelease |
| Status | missing files / update / check failed / no Forever build / pinned / up to date / unmanaged |
| Installed | date |
| Action | Update / Retry, Adopt…, progress |

Managed and unmanaged folders are separate sections, each sorted. Errors show as a red icon with the message in its tooltip and in the inspector ([errors.md](../architecture/errors.md)).

## Browse table

| Column | Shows |
|---|---|
| Name | author and a one-line summary under it |
| Forever | support badge |
| Stars | count |
| Updated | date |
| Action | Install / progress / Overwrite / Open |

- With an empty query, a **Popular / Recently Updated** switch picks the list. It's one table rather than two sections, so sorting applies to whichever list you're looking at.
- Category chips and **Forever only** run or filter the query ([search.md](../features/search.md#browse-empty-query)).
- A status bar shows the count, "Searching…" / "Searching GitHub…" while the stream is open, and **Search GitHub for More Results**.

## Sorting

- Click a header to sort, again to reverse.
- Dates and stars sort by value, versions numerically, Status by what needs attention. Missing values sort last both ways.
- The sort is remembered per table (`installedSort`, `browseSort` in user defaults, e.g. `updated.desc`). Column widths and visibility are remembered per window (`@SceneStorage`).
- Browse can return to the core's order (relevance, or stars/date for the home lists) with **Sort by Relevance** / **Default Order**.
- Rows are pre-formatted and sorted in `InstallationModel`, never in `body` ([performance/guidelines.md](../performance/guidelines.md#tables-and-lists)).
- **Never read `@Environment(SomeObservable.self)` in `Table` cells, context menus, `primaryAction` handlers or toolbar item views.** AppKit hosts them in separate hosting views; during row rebuilds (sorting, search, category changes) the object can be missing and SwiftUI traps with "No Observable object of type … found". Pass the model, row state or closures in as plain properties.

## Dates

Installed, released and updated dates read "Today" or a short date ("Oct 9, 2026"), never "x seconds ago" (`DayLabel`).

## Live updates from `addonctl`

- The app watches the store folder (`InstallStore.storeDirectory`) with a `DispatchSource` and reloads, debounced, when it changes. Add-ons installed or updated from the terminal show up immediately.
- Store-watcher reloads only re-read the add-on list, never the network.
- They're skipped when the folder's fingerprint (paths, sizes, modification dates) matches the last reload, which is what happens after the app's own writes.
- The app also reloads whenever it becomes active.

# App layout

The main window (sidebar, toolbar, inspector placement, the Installed and Browse tables, sorting) and the separate add-on window.

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

## Flavor names

Labels follow the selected installation's game, `installation.flavor.displayName` (Forever, Retail, Classic Era, TBC Anniversary, Wrath Classic, Titan, Cata Classic, Mists Classic; see [flavors.md](../architecture/flavors.md#flavors)): the Browse column, the badge and its tooltips, the "<flavor> only" toggle, Installed status, the inspector, the adopt sheet and the seeding sheet.

Forever-specific on purpose: the app name, help text and the empty state that suggests adding `World of Warcraft/_classic_beta_`.

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
| Status | missing files / update / check failed / no *<flavor>* build / pinned / up to date / unmanaged |
| Installed | date |
| Action | Update / Retry, Adopt…, progress |

- Managed and unmanaged folders are separate sections, each sorted.
- **Update** and **Update All** install the releases the last check found (`update(releases:in:)`), with no second check. With nothing available, Update All does nothing (an empty list used to mean "update everything", which was a bug).
- Errors show as a red icon with the message in its tooltip and in the inspector ([errors.md](../architecture/errors.md)).
- Action buttons in both tables (Install, Open, Overwrite, Update/Retry, Adopt…) are bordered and small.

## Browse table

| Column | Shows |
|---|---|
| Name | author and a one-line summary under it |
| *<flavor>* (e.g. Forever) | support badge |
| Stars | count |
| Updated | date |
| Action | Install / progress / Overwrite / Open |

- With an empty query, a **Popular / Recently Updated** switch picks the list. It's one table rather than two sections, so sorting applies to whichever list you're looking at.
- Category chips run their saved query; the **"<flavor> only"** toggle filters both the home lists and search results ([search.md](../features/search.md#in-the-app)).
- A status bar shows the count, "Searching…" until the last update (or "Searching GitHub…" while the core reports a live search), and **Search GitHub for More Results**. "No results" appears only after the last update.

## Sorting

- Click a header to sort, again to reverse.
- Dates and stars sort by value, versions numerically, Status by what needs attention. Missing values sort last both ways.
- The sort is remembered per table (`installedSort`, `browseSort` in user defaults, e.g. `updated.desc`). Column widths and visibility are remembered per window (`@SceneStorage`).
- Browse can return to the core's order (relevance, or stars/date for the home lists) with **Sort by Relevance** / **Default Order**.
- Rows are pre-formatted and sorted in `InstallationModel`, never in `body` ([performance/guidelines.md](../performance/guidelines.md#tables-and-lists)).
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

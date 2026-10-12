# 0012: Inspector inside the detail column, and sortable tables

The inspector is a custom split inside the detail column under the toolbar rather than SwiftUI's `.inspector`, and Browse and Installed are SwiftUI `Table`s with header sorting.

- **Status:** Accepted
- **Date:** 2026-10-11

## Context

The first app layout used SwiftUI's `.inspector` modifier. With a `NavigationSplitView`, that makes the inspector a full-height column, and the toolbar's search field moved over the right pane, above the inspector instead of the list it searches.

Browse and Installed also needed sortable columns (name, dates, stars, status) that survive a relaunch.

## Decision

**Inspector:**
- Part of the detail column's content: a small custom split (`InspectorSplit` in `ContentView.swift`).
- The toolbar and search field span the detail area; the inspector starts below them.
- Toggle with the toolbar button or ⌥⌘I; drag to resize (280–560 pt, remembered as `inspectorWidth`).

**Tables:**
- Browse and Installed are SwiftUI `Table`s with header sorting.
- Dates and stars sort **by value**, versions numerically, Status by what needs attention; missing values sort last.
- The sort is **persisted** per table (`installedSort`, `browseSort`); column widths and visibility per window (`@SceneStorage`).
- Browse's empty-query home is one table with a Popular / Recently Updated switch, so sorting applies to the visible list.
- Rows are flat, pre-formatted values built and sorted in `InstallationModel`, never in `body`.
- Dates read "Today" or a short date, never "x seconds ago".

## Alternatives considered

| Option | Why not |
|---|---|
| `.inspector` | Put the search field over the right pane |
| A third `NavigationSplitView` column | Same toolbar problem, and fixed width rules |
| `List` with custom header buttons | Re-implements what `Table` already does |
| Two sections on the Browse home | Sorting would only make sense within each section |
| Relative dates | Change every second, forcing re-renders |

## Consequences

- The search field sits above the content it searches.
- Every column is sortable and the choice survives relaunch.
- `InspectorSplit` is custom code to maintain (resize handle, width limits).
- Pre-formatted rows keep table updates cheap ([performance/guidelines.md](../performance/guidelines.md#tables-and-lists)).

## See also

- [app/layout.md](../app/layout.md)

# 0015: Read the app model from the environment only at scene roots

Only scene roots read `@Environment(AppModel.self)`; table cells, menus, toolbars, sheets and the inspector receive the model as a plain property, and a test enforces it.

- **Status:** Accepted
- **Date:** 2026-10-11

## Context

The app crashed when the user clicked a Browse category. The click rebuilt the table rows, and SwiftUI trapped with:

```
No Observable object of type AppModel found
```

SwiftUI `Table` cells, context menus, `primaryAction` handlers and toolbar item views are hosted by AppKit in **separate hosting views**. While rows are being rebuilt (sorting, search, category changes), a new cell's hosting view may not have the environment object yet. Any view inside it that reads `@Environment(AppModel.self)` then traps.

The crash only shows during rebuilds, so it's easy to miss in normal clicking and in previews.

## Decision

- **Only scene roots read `@Environment(AppModel.self)`:**
  - `ContentView` (the main window)
  - `SettingsView`
  - `MenuBarContent`
- The add-on window (`AddonWindow`) is a scene too, but it gets the model straight from the `App` as a property.
- Everything below them gets the model, the row state or closures **as plain properties**: table cells, context menus, `primaryAction` handlers, toolbar items, sheets and the inspector.
- `EnvironmentUsageTests` (in `ForeverAddonsTests`) scans the app sources and fails if any struct other than those three reads `@Environment(AppModel.self)`.
- The rule is in `.claude/CLAUDE.md` under "Code".

## Alternatives considered

| Option | Why not |
|---|---|
| Re-inject `.environment(model)` on every cell and menu | Easy to forget on one view; the crash comes back silently |
| A global singleton model | Hides dependencies; breaks multiple windows and the add-on window's own installation |
| Avoid `Table` | Loses sorting, column widths and the inspector selection ([0012](0012-inspector-and-tables.md)) |

## Consequences

- No more "No Observable object" crashes during row rebuilds.
- Views take a few more initializer parameters.
- Dependencies are visible in each view's properties, which also makes per-row observation explicit ([performance/guidelines.md](../performance/guidelines.md#progress-and-observation)).
- New views under a scene root must take the model as a property; the test catches mistakes.

## See also

- [app/layout.md](../app/layout.md#sorting)
- [architecture/concurrency.md](../architecture/concurrency.md#main-thread-rules)

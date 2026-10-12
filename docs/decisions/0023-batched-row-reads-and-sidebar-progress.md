# 0023: Read Browse rows' stored answers in one query; observe refresh progress only in the sidebar

Patching a 500-row Browse list reads every row's verdict and flavors in a single SQL query, and the window's root view no longer re-runs on every refresh progress tick.

- **Status:** Accepted
- **Date:** 2026-10-12

## Context

A performance audit after Browse grew from 20 to 500 rows per list (`SearchCoordinator.browseLimit`), with game bubbles, stored flavors and sidebar navigation. Numbers: [measurements.md](../performance/measurements.md#browse-at-500-rows-d13a961).

- **Everything else held up.** On a temp database with 5k catalogue rows and 3k verdicts, `browse(in:)` takes 8 ms and a search keystroke 5 ms, both off the main actor; every per-repo lookup uses a primary key; no transaction spans a network `await`. Rebuilding 500 rows on the main actor takes ~4 ms in a Debug build.
- **`storedAvailability(for:in:)` was an N+1.** `LiveMetadata` calls it with every listed row a database change touched; during a refresh that's up to the whole list, twice a second. It made two queries per ref through two actor hops each: 1,000 queries and 3.05 ms for 500 refs.
- **The sidebar move put progress in the root.** Since [decision 0021](0021-sidebar-navigation-and-game-picker.md), `ContentView.body` built `SidebarView`'s arguments, including `AppModel.visibleRefresh`, so it observed `RefreshStatus.progress`. Every progress event (up to 20 Hz through an ~18 s seed) re-ran the root `body`: the split view, its sheets and dialogs. [guidelines.md](../performance/guidelines.md#progress-and-observation) says only the sidebar bar and the seeding sheet observe progress.

## Decision

1. **One query per list.** `SupportCache.storedAvailability(for:flavor:)` passes the lower-cased names as a JSON array to `json_each(?)` and left-joins `support` (for the flavor) and `repo_meta` by primary key. It applies the same rules as the single-repo reads: a verdict needs a status and `checked_at`; flavors need a known source. `AddonManager.storedAvailability(for:in:)` maps the answers back to the caller's refs. The `AddonManaging` contract is unchanged. 500 refs: 0.85 ms.
2. **`SidebarHost`.** A private view in `ContentView.swift` takes the `AppModel` as a property and builds `SidebarView`'s values in its own `body`. Progress, counts and "Last fetched" now invalidate only the sidebar. `SidebarView` keeps taking plain values, so snapshot tests still render it directly, and nothing new reads the environment ([decision 0015](0015-environment-only-at-scene-roots.md)).
3. **Budgets as tests.** `DatabasePerformanceTests` (core) and `BrowsePerformanceTests` (app) time these paths on full-size data with ~10× headroom, and assert the hot queries' plans use an index.

## Alternatives considered

| Option | Why not |
|---|---|
| `WHERE full_name IN (?, ?, …)` with one placeholder per ref | A new SQL string, and a new cached statement, for every list length; SQLite also caps the number of parameters |
| A temporary table of names | Needs a write and a transaction for a read |
| Cache verdicts and flavors in memory in `SupportCache` | The CLI writes the same file; the cache would need `data_version` checks to stay right. The batched read is already under a millisecond |
| Keep the per-ref loop, and patch fewer rows | `LiveMetadata` already patches only changed, listed rows; a refresh can still touch all of them |
| Pass `RefreshStatus` into `SidebarView` | Snapshot tests and the view's plain-value inputs would change; the host gives the same isolation with no change to `SidebarView` |
| Cache `GameBubblesModel` per flavor set | 1.9 ms per 500 rows in Debug, at most twice a second: not worth the state |

## Consequences

- A refresh's live patches cost one query each, whatever the list length.
- Search per keystroke still reads every stored verdict and flavor set (3.6 ms of its 5 ms at 3k verdicts). It's off the main actor and debounced; if the database grows several times larger, read flavors and stars for the matched rows only (ranking needs every verdict).
- A new progress or count reader in `ContentView`'s own `body` would bring the per-tick root re-render back; the guideline names `SidebarHost` as the place for them.

# Performance measurements

Timings and sizes for the app, the CLI and the core: the baseline from the first performance audit (`561937a`) next to the second audit (`05ba0ff`), both Release builds, the third audit of Browse at 500 rows ([below](#browse-at-500-rows-d13a961)), and the fourth of sources at realistic sizes ([below](#sources-at-realistic-sizes)).

Update these after merges that change hot paths (see `.claude/CLAUDE.md`). The rules that follow from them: [guidelines.md](guidelines.md).

## App

| Measure | Baseline (`561937a`) | `05ba0ff` |
|---|---|---|
| Launch to first frame | ~283 ms | ~204 ms |
| Idle CPU | 0%, App Nap friendly | 0%, ~4 wakeups per 20 s |
| Idle memory | 54–78 MB (100 add-ons) | 49–70 MB |
| SwiftUI updates | 156 ms over 12 s, 17 reloads, 2 hitches | 181 ms over 12 s, ~17 reloads, 0 hitches |
| First-launch seed | n/a | ~18 s, main thread ~5% busy |
| Updating 10 add-ons | n/a | 935 ms; rows ≤10 Hz steady, ≤20 Hz in bursts |
| No-change Check for Updates | ~100 store writes | 0 store writes |
| README block parse (off main) | 19 ms for 32 KB | 1–2 ms typical, 11 ms for 32 KB |
| Inline Markdown | on main, per visible block | ~0.5 ms per 30 blocks |
| Screenshot decode | n/a | thumbnails ~0.25 MB each at 300 px; viewer ~1.5 MB at 2,000 px |

## CLI

| Command | Baseline | `05ba0ff` |
|---|---|---|
| `reload --help` | 6 ms | 4.5 ms |
| `reload list` | 10–17 ms | 8 ms empty, 14 ms with 130 add-ons |

## Core

| Operation | Baseline | `05ba0ff` |
|---|---|---|
| Catalogue CSV parse | 5 ms (9 ms with mapping) | 4.8 ms (8.9 ms with mapping) |
| Catalogue import | n/a | 24 ms |
| Catalogue load from the database | 14 ms | 2.8 ms |
| `SearchIndex` build | 63 ms | 62 ms |
| Search per keystroke | p50 0.29 ms, p95 1.47 ms | p50 0.30 ms, p95 1.47 ms |
| `recentlyUpdated` | 4.1 ms | 0.002 ms |
| 1,300 support verdicts | 4.4 s (whole-file rewrite each) | 30 ms one by one, 2.4 ms batched |
| `statuses()` | n/a | 0.6 ms |
| Install store `installations()` | 1.7 ms | 0.3 ms |
| Install store `modify` (100 add-ons) | 3.3 ms | 1.7 ms |
| `reconcile` | n/a | 4.6 ms |
| Zip validate / extract (8 MB, 400 files) | 2.5 / 107 ms | 2.4 / 106 ms |

## SQLite

System SQLite 3.54, FTS5 available.

| Operation | Baseline | `05ba0ff` |
|---|---|---|
| 2.4k-row upsert, one transaction, reused statement | 6.6 ms | 6.5 ms |
| Same, autocommit / no reused statement | 64 ms | 65 ms |
| Unchanged re-upsert | 3 ms | 2.9 ms |
| `SELECT` all rows | 1.8 ms (binary plist: 14 ms) | 1.9 ms |
| FTS5 query | p50 0.05 ms | p50 0.054 ms (`SearchIndex`: 0.30 ms) |
| WAL size after the run | grew to 4.9 MB | not re-measured (`journal_size_limit` is now 4 MB) |

Both search engines are far under one 16 ms frame, so `SearchIndex` stays ([decision 0008](../decisions/0008-sqlite-metadata-database.md)).

## What these numbers say

- Anything per keystroke is cheap. Whole-file rewrites were the outliers; batched SQLite writes fixed them.
- Statement reuse is a 10× difference in SQLite. Batches now go through `prepare` + `step`, so a loop doesn't hash a ~1 KB SQL string or box arguments per row.
- Zip extraction (106 ms) is longer than several frames. It runs off the main actor and, since 0017, before the store lock rather than inside it.

## Fixes after `05ba0ff`

From the second audit's findings ([decision 0017](../decisions/0017-details-without-quota-release-json-by-tag.md)); not yet re-measured:
- Screenshot bodies are read in the session's chunks instead of byte by byte (~62 ms CPU per MB before), and decode in parallel, 3 at a time.
- Inline Markdown is rendered while parsing, off the main actor.
- A finished update rebuilds and re-sorts the Installed table once, not twice.
- Inspector details are capped at the 20 most recently viewed add-ons.
- Zip extraction happens before the store lock.

## Browse at 500 rows (`d13a961`)

Third audit, after the Browse lists grew from 20 to 500 rows and gained game bubbles, stored flavors and the sidebar. Apple M4. Core numbers are Release (`swift test -c release -Xswiftc -enable-testing --filter DatabasePerformanceTests`) over a temp database with 5k catalogue rows, 3k Forever and 1k Retail verdicts, 3k `repo_meta` and `release_json` rows, 200 live-search answers and 100 release folder lists. App numbers are Debug unit tests (`BrowsePerformanceTests`) on the main actor, so an upper bound.

| Operation | Before | After |
|---|---|---|
| `storedAvailability` for 500 refs (a live patch of a whole list) | 3.05 ms (1,000 queries) | 0.85 ms (1 query) |
| `browse(in:)`, both 500-row lists | 8.1 ms | same |
| Search per keystroke, whole pipeline | 5.0 ms (index query 0.5 ms; reading verdicts 1.5, flavors 2.0, stars 0.2) | same |
| Refresh targets: seed / later | 1.2 / 0.9 ms | same |
| `releaseFolders()` | 0.12 ms | same |
| `BrowseModel.rebuildRows`, 500 rows: unsorted / by name / by games | 3.7–4.5 / 3.8 / 5.7 ms | same |
| `applyStored` patching all 500 rows | 4.3 ms | same |
| Progress tick during a refresh | re-ran the window's root `body` | re-runs only the sidebar |

- **Query plans.** Every per-repo lookup (support, `repo_meta`, `release_json`, `search_cache`, catalogue) uses its primary key, and the rotation query uses `support_flavor_checked`. Whole-table reads (verdicts by flavor, flavors, stars) are the intended scans. `DatabasePerformanceTests.hotQueriesUseAnIndex` keeps it that way.
- **Writes.** Flavors, stars, folders, rate limits and update states skip unchanged rows; a re-checked verdict still writes its `checked_at`, which is its TTL clock, and the Browse patch it triggers ends in an equality check that skips the rebuild. Transactions are synchronous closures, so none can span a network `await`.
- **Row building.** Of the 3 ms to build 500 `BrowseRow`s, `GameBubblesModel` is 1.9 ms and `DayLabel` 0.9 ms. That's within a frame, at most twice a second during a refresh, so it stays.
- Not re-measured: launch, idle memory, SwiftUI updates in a running app.

## Sources at realistic sizes

Fourth audit, after WoWInterface and Tukui (decision [0029](../decisions/0029-wowinterface-and-tukui-sources.md)) made the catalogue table ~4× bigger. Apple silicon, Release (`swift test -c release -Xswiftc -enable-testing --filter SourcesPerformanceTests`), over 2,400 GitHub rows (1,200 with verdicts, flavors and some stars) and a generated 5.5 MB, 8,200-file WoWInterface listing with every field the real one has. All of it runs off the main actor.

| Operation | Before | After |
|---|---|---|
| `SearchIndex` build, 8,200 hosted rows | 107 ms | 26 ms |
| `SearchIndex` build, all 10,600 rows (first search, after an import or a source toggle) | 192 ms | 42 ms |
| `SearchIndex` build, 2,400 GitHub rows | 87 ms | 19 ms |
| Listing parse (`@concurrent`) | 70 ms | same |
| Listing import, first / unchanged (one transaction) | 31 / 23 ms | same |
| Daily re-download: parse + unchanged import, WAL file | 99 ms | same |
| `catalogueEntries()`, 8,200 hosted rows | 25 ms | same |
| `enabledSources()` | <0.01 ms | same |
| Search per keystroke, whole pipeline (`b`, `bag`, `raids`, `quest frames`) | 4.9–7.7 ms | same |
| `browse(in:)`, both 500-row lists | 5.7 ms | same |

- **The fix.** `SearchText` folded each word with `String.folding` (~450 ns a word) and split camelCase per `Character`, looking up Unicode properties for every letter. ASCII text now takes byte-level paths with the same rules (`SearchTextTests.asciiFastPathsMatchTheCharacterRules` checks they agree); anything else keeps the `Character` path. Debug builds gain less (266 → 157 ms for 8,200 rows).
- **Checked, left alone.** The 23–31 ms import holds the database actor, so a search that lands during it waits that long, once a day. Search reads `enabledSources()` twice per query, which costs nothing measurable. Sharing one `JSONDecoder` for screenshot lists made no measurable difference to `catalogueEntries()`.

## Network activity

`NetworkActivityModel.flush()` on the main actor, Debug app tests (`NetworkActivityPerformanceTests`), so an upper bound. A first-launch refresh makes ~1,000 requests.

| Operation | Before | After |
|---|---|---|
| One 100 ms batch during a refresh (30 starts, 30 finishes) into 1,000 rows | 6.3 ms | 0.95 ms |
| Replaying 1,000 events (500 starts, 500 finishes) into an empty window | 50 ms | 8.3 ms |

Each event looked up its row with `lastIndex(where:)`, a scan of up to 1,000 rows (88 ms for 1,000 events over 1,000 rows); now a binary search over rows kept in ID order. What's left is formatting each row once (~11 µs) and one filter-and-compare of the visible rows per flush (~0.2 ms).

## How to measure

- Build Release, launch in the background with `RELOAD_DATA_DIR=<tmp>`, keep it brief, and quit it afterwards. Never quit the user's own running copy ([development.md](../development.md#testing-without-touching-your-real-setup)).

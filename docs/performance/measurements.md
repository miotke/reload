# Performance measurements

Timings and sizes for the app, the CLI and the core: the baseline from the first performance audit (`561937a`) next to the second audit (`05ba0ff`). Both are Release builds.

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
| `addonctl --help` | 6 ms | 4.5 ms |
| `addonctl list` | 10–17 ms | 8 ms empty, 14 ms with 130 add-ons |

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

## How to measure

- Build Release, launch in the background with `ADDONS_DATA_DIR=<tmp>`, keep it brief, and quit it afterwards. Never quit the user's own running copy ([development.md](../development.md#testing-without-touching-your-real-setup)).

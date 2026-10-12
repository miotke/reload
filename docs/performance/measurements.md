# Performance measurements

Baseline timings and sizes for the app, the CLI and the core, from the performance audit.

Measured at commit `561937a`, Release build. Update these after merges that change hot paths (see `.claude/CLAUDE.md`). The rules that follow from them: [guidelines.md](guidelines.md).

## App

| Measure | Result |
|---|---|
| Launch to first frame | ~283 ms |
| Idle CPU | 0%, App Nap friendly |
| Memory with 100 add-ons | 54–78 MB |
| SwiftUI updates | 156 ms of updates over 12 s, 17 reloads |
| README Markdown parse | 19 ms for 32 KB |

## CLI

| Command | Time |
|---|---|
| `addonctl --help` | 6 ms |
| `addonctl list` | 10–17 ms |

## Core

| Operation | Result |
|---|---|
| Catalogue CSV parse | 5 ms (9 ms with mapping to entries) |
| `SearchIndex` build | 63 ms |
| Search per keystroke | p50 0.29 ms, p95 1.47 ms |
| `SupportCache`: 1,300 sets, whole-file rewrite each time | 4.4 s (fixed by SQLite batching: 1.7 ms) |
| Install store with 100 add-ons, one `modify` | 3.3 ms |
| 100 `modify` calls | 333 ms, 45 MB written |
| Zip validate (8 MB, 400 files) | 2.5 ms |
| Zip extract (same zip) | 107 ms |

## SQLite

System SQLite 3.54, FTS5 available.

| Operation | Result |
|---|---|
| 2.4k-row upsert, one transaction, reused statement | 6.6 ms |
| Same without a reused statement | 64 ms |
| Unchanged re-upsert | 3 ms |
| `SELECT` all rows | 1.8 ms (binary plist: 14 ms) |
| FTS5 query | 0.054 ms (p50 0.05 ms, vs 0.29 ms for `SearchIndex`) |
| WAL size after the run | grew to 4.9 MB |

Both search engines are far under one 16 ms frame, so `SearchIndex` stays ([decision 0008](../decisions/0008-sqlite-metadata-database.md)).

## What these numbers say

- Anything per keystroke is cheap. Anything that rewrites a whole file per change is not: the support cache and the install store are the outliers.
- Statement reuse is a 10× difference in SQLite. Keep prepared statements.
- Markdown (19 ms) and zip extraction (107 ms) are each longer than a frame, so they must run off the main actor.

## Fixes already applied

In the app UI merge:
- Per-row observable state (`RowState`), so a progress tick re-renders one row.
- Sorting and filtering moved into the model.
- Markdown parsed off the main thread and cached.
- Screenshot thumbnails downsampled.
- Model properties assigned only when the value changed.

## How to measure

- Build Release, launch in the background with `ADDONS_DATA_DIR=<tmp>`, keep it brief, and quit it afterwards. Never quit the user's own running copy ([development.md](../development.md#testing-without-touching-your-real-setup)).

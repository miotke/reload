# 0008: SQLite metadata database through the system SQLite3 API

Remote metadata (catalogue, support, latest tags, details, cached searches) moves into one SQLite database accessed with the system SQLite3 C API; search keeps its in-memory `SearchIndex` rather than FTS5.

- **Status:** Accepted, landing with the core merge
- **Date:** 2026-10-11

## Context

Before the core merge, metadata lived in separate files: the catalogue as a binary plist, support statuses as JSON. Every change rewrote a whole file. The performance audit measured 1,300 `SupportCache` sets at **4.4 s** because of whole-file rewrites. Local-first search ([0009](0009-local-first-search.md)) and quota-free refresh ([0010](0010-quota-free-endpoints.md)) need much more stored data, queried by both the app and the CLI.

Measurements with the system SQLite 3.54 (FTS5 available):

| Operation | Time |
|---|---|
| 1,300 support sets, batched | 1.7 ms (vs 4.4 s) |
| 2.4k-row upsert, one transaction, reused statement | 6.6 ms (64 ms without reuse) |
| Unchanged re-upsert | 3 ms |
| `SELECT` all | 1.8 ms (plist: 14 ms) |
| FTS5 query | p50 0.05 ms (`SearchIndex`: 0.29 ms) |

## Decision

- **One SQLite database** for remote metadata, through `import SQLite3` (the system library).
- Settings: WAL, `synchronous=NORMAL`, `busy_timeout`, `journal_size_limit`, persistent prepared statements, `WITHOUT ROWID` where it fits, `PRAGMA optimize` on close.
- Writes are batched in transactions, skipped when nothing changed, and never held across a network `await`.
- **Keep the in-memory `SearchIndex`** for matching and ranking, built from the database. Don't use FTS5.
- The install store stays JSON ([0004](0004-transactional-installer.md)).

## Alternatives considered

| Option | Why not |
|---|---|
| GRDB | A third-party dependency; the user wants none beyond ZIPFoundation and swift-argument-parser |
| SwiftData | No full-text search, less control over queries and transactions, and awkward to use from the CLI |
| Keep JSON / plist files | Whole-file rewrites (4.4 s measured); no queries |
| FTS5 for search | Faster (0.05 vs 0.29 ms p50) but can't reproduce the ranking tiers or the aliases. Both are far under one frame, so speed doesn't decide it |

## Consequences

- Batched writes turn seconds into milliseconds.
- The app and the CLI can read the same data concurrently (WAL plus `busy_timeout`).
- A thin wrapper over the C API has to be written and tested in AddonKit.
- The WAL needs a size limit (it grew to 4.9 MB in the audit).
- The schema is being finalised in the core merge; docs describe it once it lands.

## See also

- [architecture/data-storage.md](../architecture/data-storage.md)
- [performance/measurements.md](../performance/measurements.md#sqlite)

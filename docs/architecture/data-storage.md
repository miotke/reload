# Data storage

Where every file lives, the install store's format and locking, and the SQLite metadata database.

Code: `Sources/AddonKit/Store/` (`AppDirectories`, `InstallStore`).

## Where things live

| What | Path |
|---|---|
| Installed add-on records | `~/Library/Application Support/com.andrewmiotke.ForeverAddons/installations/<installation id>.json` |
| Store lock | `…/installations/.lock` |
| CLI config | `~/Library/Application Support/com.andrewmiotke.ForeverAddons/config.json` ([cli/config.md](../cli/config.md)) |
| GitHub token | Keychain, service `com.andrewmiotke.ForeverAddons`, account `github-token` |
| Downloaded zips | `~/Library/Caches/com.andrewmiotke.ForeverAddons/downloads/<source>/<owner+repo>/<releaseID>-<asset>` |
| Catalogue and support caches | `~/Library/Caches/com.andrewmiotke.ForeverAddons/` ([caching.md](../network/caching.md)) |
| Metadata database | SQLite file, path landing with the core merge (see below) |
| Add-ons | `<WoW>/_classic_beta_/Interface/AddOns/` |

`AppDirectories` resolves these. `AppDirectories(root:)` puts everything under one folder (`<root>/Application Support`, `<root>/Caches`), which is what tests and `ADDONS_DATA_DIR` use.

Nothing is ever written into the game folder except the add-on folders themselves. No marker files.

## Install store

- Each installation has one JSON file: `{schemaVersion: 1, installation, addons: [InstalledAddon]}`. Dates are ISO-8601 with milliseconds. `schemaVersion` allows later migration.
- **Shared with the CLI** ([decision 0004](../decisions/0004-transactional-installer.md)):
  - Every write takes an exclusive `flock` on `installations/.lock`, re-reads the file inside the lock, and writes atomically.
  - `withLock` and `modify` hold the lock across a whole read-modify-write. The lock is reentrant within one store.
  - Reads skip the lock, because writes are atomic renames.
- `storeDirectory` is public so the app can watch it and reload when the CLI changes something ([app/layout.md](../app/layout.md#live-updates-from-addonctl)).

### Reconcile

`reconcile` compares the records with disk:
- Managed add-ons with missing folders are reported as `.managed(addon, missingFolders:)`.
- Folders nobody owns (excluding `Blizzard_*` and hidden files) are reported as `.unmanaged(folder:toc:suggestedRef:)`. When the folder's TOC has an `X-Website` pointing at a GitHub repo, that repo is suggested.

### Cost

Each write rewrites the whole file. With 100 add-ons one `modify` takes 3.3 ms; 100 modifies take 333 ms and write 45 MB ([measurements](../performance/measurements.md)). Batch changes into one `modify` where you can.

## Metadata database (SQLite)

> **Landing with the core merge.** What's below is decided; the schema is being finalised on the core branch. Why SQLite: [decision 0008](../decisions/0008-sqlite-metadata-database.md).

- **One SQLite database** holds remote metadata: the catalogue, Forever support and latest tags, add-on details, and cached search results.
- Accessed through the system SQLite3 C API (`import SQLite3`). No GRDB, no SwiftData.
- **Search reads only this database** ([search.md](../features/search.md)). GitHub fallback results are written into the local catalogue.
- **Each kind of data has one owner** that decides freshness, e.g. `GitHubSource.check` for support and latest tags ([decision 0011](../decisions/0011-single-cache-owner.md)).
- The install store stays JSON. Installed records are small and shared with the CLI under `flock`.

Settings (from [performance/guidelines.md](../performance/guidelines.md#sqlite)):

| Setting | Why |
|---|---|
| WAL journal, `synchronous=NORMAL` | Readers don't block the writer; fewer fsyncs |
| `busy_timeout` | App and CLI can open it at the same time |
| `journal_size_limit` | The WAL grew to 4.9 MB in the audit |
| Persistent prepared statements | 2.4k-row upsert: 6.6 ms reused vs 64 ms without |
| One transaction per batch | Never write row by row; never write when nothing changed |
| `WITHOUT ROWID` where it fits | Tables keyed by repo or text |
| `PRAGMA optimize` on close | Keeps query plans current |

Never hold a write transaction across a network `await`.

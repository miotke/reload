# Data storage

Where every file lives, the install store's format and locking, and the SQLite metadata database: its settings, schema, migrations and change stream.

Code: `Sources/AddonKit/Store/` (`AppDirectories`, `InstallStore`, `MetadataDatabase`).

## Where things live

| What | Path |
|---|---|
| Installed add-on records | `~/Library/Application Support/com.andrewmiotke.ForeverAddons/installations/<installation id>.json` |
| Store lock | `…/installations/.lock` |
| Metadata database | `~/Library/Application Support/com.andrewmiotke.ForeverAddons/metadata.sqlite` (+ `-wal`, `-shm`) |
| CLI config | `~/Library/Application Support/com.andrewmiotke.ForeverAddons/config.json` ([cli/config.md](../cli/config.md)) |
| GitHub token | Keychain, service `com.andrewmiotke.ForeverAddons`, account `github-token` |
| Downloaded zips | `~/Library/Caches/com.andrewmiotke.ForeverAddons/downloads/<source>/<owner+repo>/<releaseID>-<asset>` |
| Downloaded `release.json` files | `~/Library/Caches/com.andrewmiotke.ForeverAddons/github/release-json/` |
| Add-ons | `<WoW>/_classic_beta_/Interface/AddOns/` |

`AppDirectories` resolves these. `AppDirectories(root:)` puts everything under one folder (`<root>/Application Support`, `<root>/Caches`), which is what tests and `ADDONS_DATA_DIR` use.

Nothing is ever written into the game folder except the add-on folders themselves. No marker files.

## Install store

- Each installation has one JSON file: `{schemaVersion: 1, installation, addons: [InstalledAddon]}`. Dates are ISO-8601 with milliseconds. The JSON is compact (not pretty-printed), and listing installations decodes only the header.
- **No-op writes are skipped.** `modify` and `save` leave the file alone when nothing changed, because the app reloads on every write to `storeDirectory`. Update checks collect ETag changes and write once at the end, only if one differs.
- **Shared with the CLI** ([decision 0004](../decisions/0004-transactional-installer.md)):
  - Every write takes an exclusive `flock` on `installations/.lock`, re-reads the file inside the lock, and writes atomically.
  - `withLock` and `modify` hold the lock across a whole read-modify-write. The lock is reentrant within one store.
  - Reads skip the lock, because writes are atomic renames.
- `storeDirectory` is public so the app can watch it and reload when the CLI changes something ([app/layout.md](../app/live-data.md#live-updates-from-addonctl-installs)).
- **`reconcile`** compares the records with disk. Managed add-ons with missing folders come back as `.managed(addon, missingFolders:)`. Folders nobody owns (excluding `Blizzard_*` and hidden files) come back as `.unmanaged(folder:toc:suggestedRef:)`, with the repo from the TOC's `X-Website` suggested when it points at GitHub.

## Metadata database

Everything AddonKit knows about add-ons it hasn't installed lives in `metadata.sqlite`. It's in Application Support rather than Caches because it holds state worth keeping: verdicts, refresh times and remembered searches. Installed records stay in the JSON store. Why SQLite: [decision 0008](../decisions/0008-sqlite-metadata-database.md).

`MetadataDatabase` is a small actor over the system SQLite (`import SQLite3`, no packages):
- It owns the connection, opened without SQLite's mutex, since the actor already serializes access.
- **Shared with the CLI:** WAL mode, `synchronous=NORMAL`, a 5 s busy timeout, `foreign_keys=ON`, `journal_size_limit` 4 MB, `PRAGMA optimize` on close.
- Prepared statements are cached by SQL text. Arguments bind as `Int`/`Int64`, `Double`, `String`, `Data`, `Bool`, `Date` (Unix seconds) or nil. Text and blobs are copied (`SQLITE_TRANSIENT`).
- `transaction { }` uses `BEGIN IMMEDIATE`. Its body is synchronous, so a write lock is never held across a network wait.
- Failures throw `SQLiteError` with SQLite's message.

### Schema

| Table | Key | Holds |
|---|---|---|
| `catalogue` | `full_name` (no case) | catalogue rows; `source` is `catalogue` or `github_search`; `first_seen_at`, `changed_at` |
| `catalogue_state` | single row | ETag, last fetch, last failure |
| `support` | `full_name` + `flavor` | verdict (`supported`, `unsupported`, `noReleases`, `needsDownload`, or `error`), version, the tag it was based on, `checked_at` |
| `repo_meta` | `full_name` | latest tag and when it was seen, publish date if known, stars, README path and ETag |
| `details` | `full_name` + `flavor` | README, screenshot URLs, latest release notes for the inspector |
| `refresh_state` | installation ID | last refresh time and the update states it found |
| `search_cache` | normalised query | repos a live search returned, and when |
| `rate_limit` | `core` / `search` | remaining calls and reset time |

- `catalogue` and `support` are `WITHOUT ROWID` tables. `catalogue(last_updated)` and `support(flavor, checked_at)` are indexed for the refresh queries.
- How long each kind of row is trusted: [network/caching.md](../network/caching.md#lifetimes). Only `GitHubSource` writes `support` and `repo_meta` tags ([decision 0011](../decisions/0011-single-cache-owner.md)).

### Migrations

- An ordered list of SQL steps. `PRAGMA user_version` counts how many have run.
- Each new step runs in its own `BEGIN IMMEDIATE` transaction when the database opens, re-checking the version inside the lock so the app and CLI can't both apply it.
- Shipped steps are never edited; add a new one.

| `user_version` | Step |
|---|---|
| 1 | The schema above |
| 2 | `classic` was split into `vanilla`, `tbc`, `wrath`, `titan`, `cata` and `mists` ([decision 0016](../decisions/0016-one-flavor-per-game.md)). Deletes `support` and `details` rows with `flavor = 'classic'`; they're re-checked under the new flavors. `forever` and `mainline` rows stay. `refresh_state` is keyed by installation, so it's left alone |

### Change stream

- `MetadataDatabase.changes()` streams the tables and repos each commit touched, so the UI can patch only affected rows.
- Writes from another process (the CLI) don't appear there. Compare `dataVersion()` (`PRAGMA data_version`) on app activation instead.

### Old caches

Earlier versions kept `catalogue.plist` and `forever-support.json` in Caches. They're no longer read or written.

## Cost

- Install store: each write rewrites the whole file. With 100 add-ons one `modify` takes 3.3 ms; 100 modifies take 333 ms and write 45 MB. Batch changes into one `modify`.
- SQLite: a 2.4k-row upsert in one transaction with a reused statement takes 6.6 ms (64 ms without). More in [measurements](../performance/measurements.md#sqlite) and the [rules](../performance/guidelines.md#sqlite).

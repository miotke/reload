# 0004: Transactional installer and a locked JSON install store

Installs stage and back up folders and roll back on failure, uninstalls go to the Trash, and installed records live in one JSON file per installation, locked with `flock` and shared by the app and CLI.

- **Status:** Accepted
- **Date:** 2026-10-11

## Context

Installing is the riskiest thing the app does: it replaces folders in the user's `Interface/AddOns`. A crash or a bad zip must never leave that folder half-written, and the app must never delete a folder it didn't install without asking.

The app and the CLI can run at the same time and both write the record of what's installed.

## Decision

**Installer:**
1. Validate the whole zip before touching disk: reject `..`, absolute and symlink entries (zip-slip), and `Blizzard_*` folders. (Stray top-level files were rejected at first; they're now skipped, since packagers ship READMEs and build notes there.)
2. Check folder ownership: replace own folders, refuse another add-on's (`folderConflict`), and require `force` to overwrite an unmanaged one.
3. Extract into a staging folder on the same volume, so moves are atomic renames.
4. Move each old folder to a backup, move the new one in. **On any failure, restore backups in reverse order.** If that fails too, keep the staging folder.

**Uninstall** moves folders to the Trash, not `rm`.

**Install store:**
- One JSON file per installation in Application Support, with a `schemaVersion`.
- Every write takes an exclusive `flock` on `installations/.lock`, re-reads inside the lock and writes atomically.
- The ownership check, folder swap and store write run as one step under that lock.
- Nothing is written into the game folder except the add-on folders. No marker files.

## Alternatives considered

| Option | Why not |
|---|---|
| Extract straight into `AddOns` | A failure mid-way leaves a broken add-on |
| Delete on uninstall | No undo if the user picked the wrong add-on |
| Marker files in each add-on folder | Writes into the game folder; lost when an add-on updates itself |
| An actor-only lock | Doesn't protect against the CLI in another process |
| SQLite for installed records | Small data; JSON is easy to inspect and diff. Remote metadata goes to SQLite instead ([0008](0008-sqlite-metadata-database.md)) |

## Consequences

- An interrupted install leaves the old version in place.
- The app and CLI never interleave writes; the app watches the folder and reloads.
- Each write rewrites the whole file: 3.3 ms per `modify` with 100 add-ons, 333 ms for 100 modifies. Fine for user actions; batch where possible.
- Rollback works offline from the last 2 cached zips.

## See also

- [features/installing.md](../features/installing.md)
- [architecture/data-storage.md](../architecture/data-storage.md)

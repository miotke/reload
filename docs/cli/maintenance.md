# CLI maintenance commands

The `addonctl refresh`, `cache` and `doctor` commands: keeping metadata current, clearing caches and the metadata database, and checking the setup.

Command list: [commands.md](commands.md). Where the files live: [data-storage.md](../architecture/data-storage.md).

## refresh

```sh
addonctl refresh            # like the app's 2-hour refresh
addonctl refresh --force    # refresh now, re-checking every installed add-on
```

- Runs the core's refresh for the chosen installation: catalogue, update checks, Forever verdicts ([features/refresh.md](../features/refresh.md)).
- If the last refresh was under 2 hours ago, it says `Already refreshed …; use --force to refresh now.` and does nothing.
- On a terminal, one progress line is redrawn on stderr. Afterwards it prints a summary per phase, plus a table of available updates (UPDATE / INSTALLED / LATEST).
- Checks go to github.com, so add-ons with a `release.json` cost no API quota; ones without may still need an API call.
- `--json` returns `{installation, skipped, lastRefresh, updates[]}`.

## cache

| Command | What it does |
|---|---|
| `cache info` | Lists what's in Caches (downloads, `release.json` files, stale cache files) and `metadata.sqlite` plus its write-ahead log in Application Support, with file counts and sizes. JSON gains `metadataDatabase` (the path) |
| `cache clear` | Empties the Caches folder only. Asks first, because rollback needs the cached zips |
| `cache clear --metadata` | Also empties the metadata database. Asks a second time, because search finds nothing until the catalogue is downloaded again |

`--metadata` details:
- Empties `catalogue`, `catalogue_state`, `repo_meta`, `support`, `details`, `refresh_state` and `search_cache` in one transaction, then runs `wal_checkpoint(TRUNCATE)` and `VACUUM`.
- **Keeps the database file**, because the app may have it open, and deleting an open WAL database corrupts it.
- **Keeps `rate_limit`**: forgetting an exhausted quota would let the app and CLI spend requests GitHub will refuse.
- Afterwards, run `addonctl refresh` to rebuild it. The app picks up the change on activation ([app/live-data.md](../app/live-data.md)).

Without a terminal, both confirmations need `--yes` ([output.md](output.md)).

## doctor

One row per check, marked ✓ (ok), `!` (warning) or error. Exit 1 if any check is an error.

| Row | Checks |
|---|---|
| Installations | found, default still exists |
| Each installation | `AddOns` readable; store readable; managed and unmanaged counts; add-ons with missing folders; folders claimed by two add-ons |
| Metadata | `metadata.sqlite` opens, schema version, size, catalogue and support row counts. Warns when the catalogue is empty (run `addonctl refresh`) |
| Refresh *(per installation)* | when it was last refreshed, or a warning if never |
| GitHub API | the stored `core` rate-limit state: remaining calls and reset time; warns below 10 |
| GitHub search | the stored `search` rate-limit state; warns below 3; "No live searches recorded" if none |
| GitHub token | set, and from where; a warning if not set (60 calls/hour) |
| WoW | running or not |
| Data | a warning when `ADDONS_DATA_DIR` is in use |

- GitHub rows read the **stored** rate-limit state, which costs nothing. Only when nothing is stored does `doctor` call the free `GET /rate_limit`.
- `--json` returns `{healthy, checks[]}`.

# CLI output

How `reload` prints results: global options, tables, JSON, progress, errors, exit codes, environment variables and shell completions.

Commands: [commands.md](commands.md).

## Global options

Accepted by every command (they go after the command name).

| Option | Meaning |
|---|---|
| `-I, --install <id\|path>` | Which installation to use ([choosing](commands.md#choosing-the-installation)) |
| `--json` | One JSON document on stdout, no prompts, colour or progress |
| `-y, --yes` | Assume yes for confirmations |
| `-q, --quiet` | Only essential output (tables and errors) |
| `-v, --verbose` | Extra detail on stderr, and up-to-date rows in `update` |
| `--no-color` | No ANSI colour. Colour is also off when stdout isn't a terminal, `NO_COLOR` is non-empty, or `TERM=dumb` |

## Terminal output

```
$ reload search boss
  NAME                 REPO                              GAMES  UPDATED
  BigWigs              BigWigsMods/BigWigs               R F C  2 days ago   (installed)
  DBM - Core           DeadlyBossMods/DeadlyBossMods     R F C  3 days ago
  RetailOnly           someone/RetailOnly                R · ·  5 days ago
  BossTimers           someone/BossTimers                —      1 week ago

$ reload update
  BigWigs      v426.3 → v426.4   ━━━━━━━━━━━━━━━━━━━━ done
  BugSack      pinned, skipped
```

- Aligned tables go to stdout.
- **GAMES** (`search`, `list`, `info`): which games the latest release ships builds for, in fixed positions: **R** Retail, **F** Forever, **C** Classic, `·` for a family with no build. On a terminal R is blue, F cyan, C yellow, and the installation's own family is bold. `—` (dimmed) means not known: no `release.json`, or the check couldn't run; it's not a warning. `Format.games`.
- Progress rows and spinners go to **stderr**, and only when stderr is a terminal. When it isn't, each result is printed as a line on stdout instead.
- After anything that changed files, `WoW is running; type /reload to load the changes.` is printed if an app with bundle id `com.blizzard.worldofwarcraft` is running.

## JSON (`--json`)

- One pretty-printed document with `"schemaVersion": 1` and ISO-8601 dates.
- Codable model types (`InstalledAddon`, `Installation`, `AddonRef`) are encoded as is.
- The rest use CLI wrappers in `JSONOutput.swift`:

| Wrapper | Shape |
|---|---|
| `ReleaseJSON` | all `ResolvedRelease` fields including `reasoning` |
| `SupportJSON` | `{"status": "supported", "version": …}` |
| `UpdateStateJSON` | `{"state": "available", "version": …, "release": …}`; `release` may be missing (only `version` known), and `state` can be `unknown` |
| `SearchResultJSON` | a search result, plus `availableFlavors` (flavor raw values in `Flavor.allCases` order) and `families` (`retail`, `forever`, `classic`); both absent when not checked |
| `AddonStatusJSON` | `{"kind": "managed"\|"unmanaged", …}`; unmanaged entries add `folders`, `title` and `tocVersion` (from the TOC the game loads), `tocFile`, `supportsFlavor`, `suggestedRef` and `candidates` (`ref`, `name`, `reason`, `confidence`); every entry may carry `availableFlavors` and `families`. A managed `addon` has `installedFlavorBuild` (`mainline`) when it's a Retail build on Forever; managed entries list required folders that aren't installed in `missingDependencies` |
| `MissingDependencyJSON` | `{"folder": "BigWigs", "requiredBy": [ref], "candidates": [{ref, name, reason}], "suggested": {ref, name, reason}}`; `suggested` is absent when no candidate is certain ([dependencies.md](../features/dependencies.md#candidates)) |

- Batch commands report `installed` / `updated` / `removed` plus `failed: [{ref, code, message}]`.

Per-command documents:

| Command | Top-level fields |
|---|---|
| `search` | `query`, `searchedGitHub`, `results` |
| `info` | the add-on plus `support`, `availableFlavors`, `families`, `games` (the sentence), `latestVersion`, `latestPublishedAt`, `readmePath`, `screenshots` (a count), `detailsFetchedAt`, `detailsError`, `lastUpdated`, `changelog`, `updateState`; `latest` (a `ReleaseJSON`) only for prereleases |
| `install` | `installation`, `installed`, `failed`, `missingDependencies[]` (`MissingDependencyJSON`) |
| `remove` | `installation`, `removed`, `failed`, `stopLoading` (refs of add-ons that needed a removed one) |
| `refresh` | `installation`, `skipped`, `lastRefresh`, `updates[]` |
| `cache info` | cache sizes plus `metadataDatabase` |
- `export` prints the [`addons.json`](config.md#addonsjson) itself.

## Errors

Errors go to stderr:
- Terminal: `error: <message>`, with a hint where useful (e.g. "Retry with --force").
- `--json`: `{"error":{"code":"unmanaged_folder","message":"…"}}`.

Messages come from [`AddonError`](../architecture/errors.md) or the CLI's own `CLIError`.

JSON error codes: `invalid_reference`, `not_found`, `no_compatible_release`, `rate_limited`, `http_error`, `invalid_archive`, `unsafe_archive`, `folder_conflict`, `unmanaged_folder`, `not_installed`, `no_rollback`, `installation_not_found`, `cannot_remove`, `usage`, `ambiguous_reference`, `no_installation`, `ambiguous_installation`, `confirmation_required`, `cancelled`, `partial_failure`, `failed`, `error`. `no_forever_installation` was removed with `CLIError.noForeverInstallation`: any single installation is used now ([commands.md](commands.md#choosing-the-installation)).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | General error (not found, no installation, network, cancelled) |
| 2 | Usage error: bad arguments, ambiguous ref or installation, confirmation needed |
| 3 | Partial failure: some add-ons in a batch failed |
| 4 | Rate limited |
| 5 | Conflict or unmanaged folder (retry with `--force`) |
| 10 | Outdated (`outdated` only) |

- A batch where every item failed for the same reason exits with that reason's code (one conflicting install → 5). Mixed results → 3.
- `update` only gets messages from `OperationEvent.failed`, so it recognises rate limiting from the message text.

## Environment

| Variable | Effect |
|---|---|
| `RELOAD_GITHUB_TOKEN`, then `GITHUB_TOKEN` | Override the Keychain token for this run |
| `RELOAD_DATA_DIR` | Keep all data under this folder (`AppDirectories(root:)`) and skip WoW auto-detection, so only `installs add` installations exist. Use it for testing |
| `NO_COLOR` | Disable colour |

## Shell completions

```sh
reload --generate-completion-script zsh > ~/.zfunc/_reload
```

`<ref>` arguments complete installed add-on names and `owner/repo`s, read straight from the store files (no network, honours `RELOAD_DATA_DIR`).

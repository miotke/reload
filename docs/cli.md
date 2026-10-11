# Command-line tool (addonctl)

`addonctl` is a package-manager-style CLI over the same core (`AddonManager`) and the same installed add-on records as the app. An add-on installed in one shows up in the other. The spec is [design.md §9](design.md#9-cli-addonctl).

Code: `Sources/addonctl/`. It's built by SwiftPM (`swift build --product addonctl`) and also by the Xcode project, which compiles the same folder with `-parse-as-library` into the helper at `ForeverAddons.app/Contents/Helpers/addonctl`. The entry point is `@main struct AddonCtl` in `AddonCtl.swift`; there's no `main.swift` and no SwiftPM resources.

## Installing it

- **From the app:** on first launch the app offers to install it, creating the symlink `/usr/local/bin/addonctl` → the binary inside the app (admin password needed). You can also install it later from Settings ▸ Command-Line Tool. See [app.md](app.md#command-line-tool-install).
- **From source:** `swift build -c release --product addonctl`, then put `.build/release/addonctl` on your `PATH`.

## Commands

| Command | Aliases | What it does |
|---|---|---|
| `search <query…>` | `s` | Same search as the Browse tab. Waits for the stream to finish (Forever verification) behind a spinner, then prints NAME / REPO / FOREVER / UPDATED. `--github` adds live GitHub search, `--all` keeps add-ons verified unsupported, `--limit N` (default 20) |
| `info <ref>` | `show` | Description, website, latest Forever release and the selector's reasoning, installed version, update status, owned folders, rollback target. `--changelog` adds release notes, `--prerelease` looks at prereleases |
| `install <ref…>` | `i`, `add` | Installs one after another with a progress row each. `--prerelease`, `--force` (overwrite unmanaged folders), `--version <tag>` (pins it; see limits below). Re-installing keeps the add-on's channel unless `--prerelease` is given; new installs use `default-channel` |
| `remove <ref…>` | `rm`, `uninstall` | Moves folders to the Trash after confirmation |
| `update [<ref…>]` | `upgrade`, `up` | Updates everything, or the named add-ons, driven by `OperationEvent`s. Pinned add-ons are listed as skipped. `--dry-run` shows the `outdated` table and what would be skipped |
| `outdated` | | NAME / INSTALLED / LATEST / CHANNEL / PUBLISHED for available updates. Exit code 10 if any |
| `list` | `ls` | Managed add-ons with version, repo, channel and state (pinned, missing folders). `--unmanaged` adds unmanaged folders with their suggested ref; `--missing` shows only add-ons with missing folders |
| `pin <ref…>` / `unpin <ref…>` | | Pin or unpin, so `update` skips them |
| `channel <ref> stable\|prerelease` | | Set the release channel (applies on the next `update`) |
| `rollback <ref>` | | Reinstall `previousRelease` from the download cache and pin it. Asks first |
| `adopt [<folder> <ref>]` | | Start managing an unmanaged folder. With no arguments, walks every unmanaged folder that has a suggested ref (from the TOC's `X-Website`), grouping folders of the same add-on, and asks for each |
| `resolve <ref>` | | Dry run: flavor, channel, version, release id, asset, download URL and the numbered `ResolvedRelease.reasoning`. `--prerelease` |
| `installs` | | Lists installations (runs detection) with `*` on the default. Subcommands: `add <path>`, `remove <id>` (forgets it; files stay), `default <id\|path>` |
| `export [-o file]` | | Writes `addons.json` to stdout or a file |
| `import <file\|->` | | Installs every entry not already installed; for installed ones it only syncs channel and pin. `--force` |
| `config get\|set\|unset <key>` | | Keys below |
| `cache info\|clear` | | Sizes of downloads, catalogue, support checks and other cached files; `clear` asks first (it removes rollback archives) |
| `doctor` | | Installations found, each `AddOns` folder readable, store integrity (missing folders, folders claimed by two add-ons), GitHub reachability and rate limit (`GET /rate_limit`, free), token source, whether WoW is running. Exit 1 if any check fails |

Destructive commands (`remove`, `adopt`, `rollback`, `cache clear`) need confirmation: a `[y/N]` prompt on a terminal, otherwise `--yes`, or they fail with exit 2.

### `<ref>`

`owner/repo`, `https://github.com/owner/repo` (also `/releases…`, `.git`), `github:owner/repo`, or a name. Names go through `AddonManager.lookup`: installed add-ons first (name, repo name or folder, case-insensitive), then an exact catalogue name. Several matches → a numbered pick on a terminal, otherwise an error listing the candidates (exit 2). No match → exit 1 with a hint to `search`.

### Choosing the installation

1. `-I/--install`: an installation id, a unique id prefix (4+ characters), or a path (the flavor folder, its `Interface/AddOns`, or the `World of Warcraft` folder).
2. `config default-install`, if it still exists.
3. The only Forever installation.
4. Several Forever installations: a numbered pick on a terminal, otherwise exit 2 listing them. None at all: exit 1.

`search`, `info` and `resolve` also work with no installation, against a placeholder Forever one.

### Config

| Key | Stored in | Notes |
|---|---|---|
| `github-token` | Keychain (service `com.andrewmiotke.ForeverAddons`, account `github-token`) | `set` reads stdin (no echo on a terminal) and refuses a value on the command line. `get` prints it masked (`ghp_…abcd`) with its source; `ADDONS_GITHUB_TOKEN` / `GITHUB_TOKEN` win |
| `default-channel` | `<Application Support>/config.json` | `stable` or `prerelease` |
| `default-install` | `<Application Support>/config.json` | Validated against known installations; a path is added first |

### `addons.json`

```json
{
  "schemaVersion": 1,
  "exportedAt": "2026-10-11T23:49:53Z",
  "addons": [
    { "ref": "github:BigWigsMods/BigWigs", "name": "BigWigs", "channel": "stable", "pinned": true, "version": "v426.4" }
  ]
}
```

`version` is written only for pinned add-ons.

## Global options

Accepted by every command (they go after the command name).

| Option | Meaning |
|---|---|
| `-I, --install <id\|path>` | Which installation to use (see above) |
| `--json` | One JSON document on stdout, no prompts, colour or progress |
| `-y, --yes` | Assume yes for confirmations |
| `-q, --quiet` | Only essential output (tables and errors) |
| `-v, --verbose` | Extra detail on stderr, and up-to-date rows in `update` |
| `--no-color` | No ANSI colour. Colour is also off when stdout isn't a terminal, `NO_COLOR` is non-empty, or `TERM=dumb` |

## Output

- **Terminal:** aligned tables on stdout. Progress rows (`name  v1 → v2  ━━━━━━━━  done`) and spinners go to **stderr** and only when stderr is a terminal; when it isn't, each result is printed as a line on stdout instead. After anything that changed files, `WoW is running; type /reload to load the changes.` is printed if an app with bundle id `com.blizzard.worldofwarcraft` is running.
- **`--json`:** one pretty-printed document with `"schemaVersion": 1` and ISO-8601 dates. Codable model types (`InstalledAddon`, `Installation`, `AddonRef`) are encoded as is; the rest use CLI wrappers in `JSONOutput.swift`: `ReleaseJSON` (all `ResolvedRelease` fields including `reasoning`), `SupportJSON` (`{"status": "supported", "version": …}`), `UpdateStateJSON` (`{"state": "available", "release": …}`), `SearchResultJSON`, `AddonStatusJSON` (`{"kind": "managed"|"unmanaged", …}`). Batch commands report `installed`/`updated`/`removed` plus `failed: [{ref, code, message}]`. `export` prints the `addons.json` itself.
- **Errors** go to stderr: `error: <message>` with a hint where useful (e.g. "Retry with --force"), or `{"error":{"code":"unmanaged_folder","message":"…"}}` with `--json`.

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

A batch where every item failed for the same reason exits with that reason's code (one conflicting install → 5); mixed results → 3. `update` only gets messages from `OperationEvent.failed`, so it recognises rate limiting from the message text.

## Environment

| Variable | Effect |
|---|---|
| `ADDONS_GITHUB_TOKEN`, then `GITHUB_TOKEN` | Override the Keychain token for this run |
| `ADDONS_DATA_DIR` | Keep all data under this folder (`AppDirectories(root:)`) and skip WoW auto-detection, so only `installs add` installations exist. Use it for testing |
| `NO_COLOR` | Disable colour |

## Shell completions

```sh
addonctl --generate-completion-script zsh > ~/.zfunc/_addonctl
```

`<ref>` arguments complete installed add-on names and `owner/repo`s, read straight from the store files (no network, honours `ADDONS_DATA_DIR`).

## Limits

- `install --version <tag>` only succeeds when `<tag>` is the release the selector picks today (then it installs and pins it); AddonKit can't install an older tag yet. `import` warns and installs the current release (still pinned) in that case.
- `search` waits for verification, but `GitHubSource` keeps a reserve of API calls, so with little quota left results show `? unknown`.

## Code layout

| File | Contents |
|---|---|
| `AddonCtl.swift` | Root command, subcommand list, `main` mapping errors to exit codes and JSON errors |
| `Context.swift` | `GlobalOptions`, `CLIContext` (output, prompts, installation and ref choice), `ContextCommand` |
| `Selection.swift` | Pure installation and ref selection |
| `Table.swift`, `Terminal.swift` | Tables and formatting; `Style`, `Console`, `Prompter`, `Spinner`, `ProgressBoard` |
| `JSONOutput.swift`, `Errors.swift` | JSON documents and wrappers; `CLIError`, `ExitStatus` |
| `Config.swift`, `AddonsFile.swift`, `Environment.swift` | `config.json` + Keychain, `addons.json`, `ADDONS_DATA_DIR`, WoW-running check, completion |
| `Commands/` | One file per command group |

Tests: `Tests/addonctlTests` (`@testable import addonctl`) cover selection, tables, JSON shapes, exit-code mapping, export/import, colour rules, config and completion.

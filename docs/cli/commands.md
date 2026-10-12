# CLI commands

Every `addonctl` command, how `<ref>` arguments are resolved, and how the installation is chosen.

`addonctl` is a package-manager-style CLI over the same core (`AddonManager`) and the same install store as the app. An add-on installed in one shows up in the other. Output, exit codes and environment: [output.md](output.md). Config keys and `addons.json`: [config.md](config.md).

## Installing it

- **From the app:** on first launch the app offers to install it, creating the symlink `/usr/local/bin/addonctl` → the binary inside the app (admin password needed). You can also install it later from Settings ▸ Command-Line Tool. See [app/cli-install.md](../app/cli-install.md).
- **From source:** `swift build -c release --product addonctl`, then put `.build/release/addonctl` on your `PATH`.

## Commands

| Command | Aliases | What it does |
|---|---|---|
| `search <query…>` | `s` | Same local-first search as the Browse tab; see [search](#search). Prints NAME / REPO / FOREVER / UPDATED. `--github` adds a deeper live GitHub search, `--all` keeps add-ons verified unsupported, `--limit N` (default 20) |
| `info <ref>` | `show` | Description, website, Forever support, latest version, installed version, update status, owned folders, rollback target; see [info](#info). `--changelog` adds release notes, `--prerelease` looks at prereleases |
| `install <ref…>` | `i`, `add` | Installs one after another with a progress row each. `--prerelease`, `--force` (overwrite unmanaged folders), `--version <tag>` (pins it; see [limits](config.md#limits)). Re-installing keeps the add-on's channel unless `--prerelease` is given; new installs use `default-channel` |
| `remove <ref…>` | `rm`, `uninstall` | Moves folders to the Trash after confirmation |
| `update [<ref…>]` | `upgrade`, `up` | Checks, then installs only what has an update; see [update](#update). Pinned add-ons are listed as skipped. `--dry-run` shows the `outdated` table and what would be skipped |
| `outdated` | | NAME / INSTALLED / LATEST / CHANNEL / PUBLISHED for available updates. Always revalidates. Exit code 10 if any |
| `list` | `ls` | Managed add-ons with version, repo, channel and state (pinned, missing folders). `--unmanaged` adds unmanaged folders with their suggested ref; `--missing` shows only add-ons with missing folders |
| `pin <ref…>` / `unpin <ref…>` | | Pin or unpin, so `update` skips them |
| `channel <ref> stable\|prerelease` | | Set the release channel (applies on the next `update`) |
| `rollback <ref>` | | Reinstall `previousRelease` from the download cache and pin it. Asks first |
| `adopt [<folder> <ref>]` | | Start managing an unmanaged folder. With no arguments, walks every unmanaged folder that has a suggested ref (from the TOC's `X-Website`), grouping folders of the same add-on, and asks for each |
| `resolve <ref>` | | Dry run: flavor, channel, version, release id, asset, download URL and the numbered [reasoning trail](../features/release-selection.md#reasoning-trail). `--prerelease` |
| `installs` | | Lists installations (runs detection) with `*` on the default. Subcommands: `add <path>`, `remove <id>` (forgets it; files stay), `default <id\|path>` |
| `export [-o file]` | | Writes [`addons.json`](config.md#addonsjson) to stdout or a file |
| `import <file\|->` | | Installs every entry not already installed; for installed ones it only syncs channel and pin. `--force` |
| `config get\|set\|unset <key>` | | [Config keys](config.md#config-keys) |
| `refresh [--force]` | | Refresh the catalogue, update checks and Forever verdicts, like the app's 2-hour refresh ([maintenance.md](maintenance.md#refresh)) |
| `cache info\|clear` | | Sizes of caches and the metadata database; `clear` empties Caches, `clear --metadata` also empties the database ([maintenance.md](maintenance.md#cache)) |
| `doctor` | | Installations, `AddOns` folders, store integrity, the metadata database, refresh state, GitHub quota, token source, whether WoW is running. Exit 1 if any check fails ([maintenance.md](maintenance.md#doctor)) |

Destructive commands (`remove`, `adopt`, `rollback`, `cache clear`) need confirmation: a `[y/N]` prompt on a terminal, otherwise `--yes`, or they fail with exit 2.

## search

- **No support checks.** Badges are the stored verdicts: `✓ <version>`, `— not yet`, `— no releases`, `? needs download` (no `release.json`) or `? unknown` (never checked).
- It asks GitHub only when there are fewer than 3 local matches (3+ character query), or with `--github`. When it does so on its own, it prints `Few local matches, so GitHub was searched too.` on stderr.
- A spinner shows "Searching GitHub…" while the live search runs (terminal only).
- `--json` output gains `searchedGitHub`.
- How search works: [features/search.md](../features/search.md).

## info

- Reads stored details (`catalogueEntry(for:)`, `details(for:in:)`), which refresh after a day. Stale details may spend one API call on release notes when more than 30 calls remain.
- Shows support, latest version and date, README path, screenshots, when details were fetched and any fetch error, last updated, and the changelog with `--changelog`.
- "Asset" and "Why this release" (the [reasoning trail](../features/release-selection.md#reasoning-trail)) appear only for prereleases.
- `updateState` can be `unknown`, or `available` with just a `version`. JSON fields: [output.md](output.md#json---json).

## update

- With no refs, it **checks everything first, always revalidating**, then installs only the `.available` releases (`update(releases:in:)`).
- A no-change update costs no API quota for add-ons with a `release.json`.
- Rate limits are recognised from the stored rate-limit state.

## `<ref>`

Accepted forms:
- `owner/repo`
- `https://github.com/owner/repo` (also `/releases…`, `.git`)
- `github:owner/repo`
- a name

Names go through `AddonManager.lookup`: installed add-ons first (name, repo name or folder, case-insensitive), then an exact catalogue name.

| Matches | Result |
|---|---|
| One | Used |
| Several | A numbered pick on a terminal; otherwise an error listing the candidates (exit 2) |
| None | Exit 1 with a hint to `search` |

## Choosing the installation

1. `-I/--install`: an installation id, a unique id prefix (4+ characters), or a path (the flavor folder, its `Interface/AddOns`, or the `World of Warcraft` folder).
2. `config default-install`, if it still exists.
3. The only Forever installation.
4. Several Forever installations: a numbered pick on a terminal, otherwise exit 2 listing them. None at all: exit 1.

`search`, `info` and `resolve` also work with no installation, against a placeholder Forever one.

## Code layout

| File | Contents |
|---|---|
| `AddonCtl.swift` | Root command (`@main struct AddonCtl`), subcommand list, `main` mapping errors to exit codes and JSON errors |
| `Context.swift` | `GlobalOptions`, `CLIContext` (output, prompts, installation and ref choice), `ContextCommand` |
| `Selection.swift` | Pure installation and ref selection |
| `Table.swift`, `Terminal.swift` | Tables and formatting; `Style`, `Console`, `Prompter`, `Spinner`, `ProgressBoard` |
| `JSONOutput.swift`, `Errors.swift` | JSON documents and wrappers; `CLIError`, `ExitStatus` |
| `Config.swift`, `AddonsFile.swift`, `Environment.swift` | `config.json` + Keychain, `addons.json`, `ADDONS_DATA_DIR`, WoW-running check, completion |
| `Commands/` | One file per command group |

Built by SwiftPM (`swift build --product addonctl`) and by the Xcode project ([app/project.md](../app/project.md#targets)). There's no `main.swift` and no SwiftPM resources.

Tests: `Tests/addonctlTests` (`@testable import addonctl`) cover selection, tables, JSON shapes, exit-code mapping, export/import, colour rules, config and completion.

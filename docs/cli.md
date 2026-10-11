# Command-line tool (addonctl)

`addonctl` is a package-manager-style CLI over the same core and the same installed add-on records as the app. An add-on installed in one shows up in the other.

> **Status:** the commands below are being implemented. Today's `main` has only the entry point. This page describes the target behaviour from [design.md §9](design.md#9-cli-addonctl), and will be updated when the commands land.

Code: `Sources/addonctl/`. It's built by SwiftPM (`swift build --product addonctl`) and also by the Xcode project, which embeds it in the app at `ForeverAddons.app/Contents/Helpers/addonctl`.

## Installing it

- **From the app:** on first launch the app offers to install it, creating the symlink `/usr/local/bin/addonctl` → the binary inside the app (admin password needed). You can also install it later from Settings ▸ Command-Line Tool. See [app.md](app.md#command-line-tool-install).
- **From source:** `swift build -c release --product addonctl`, then put `.build/release/addonctl` on your `PATH`.

## Commands

| Command | Aliases | What it does |
|---|---|---|
| `search <query…>` | `s` | Search, same as the Browse tab. Options: `--github`, `--all`, `--limit N` |
| `info <ref>` | `show` | Details, latest Forever release and why it was chosen, owned folders. `--changelog` adds release notes |
| `install <ref…>` | `i`, `add` | Install. Options: `--prerelease`, `--version <tag>` (installs that tag and pins it), `--force` |
| `remove <ref…>` | `rm`, `uninstall` | Move the add-on's folders to the Trash |
| `update [<ref…>]` | `upgrade`, `up` | Update everything, or the named add-ons. `--dry-run` shows what would change |
| `outdated` | | List available updates. Exits with code 10 if anything is outdated |
| `list` | `ls` | Managed add-ons. `--unmanaged` adds unmanaged folders; `--missing` shows only add-ons with missing folders |
| `pin` / `unpin <ref…>` | | Pin or unpin, so `update` skips them |
| `channel <ref> stable\|prerelease` | | Set the release channel |
| `rollback <ref>` | | Reinstall the previous version (and pin it) |
| `adopt [<folder> <ref>]` | | Start managing a hand-installed folder |
| `resolve <ref>` | | Dry run: which release and zip would be chosen, and why |
| `installs` | | List installations. Subcommands: `add <path>`, `remove <id>`, `default <id>` |
| `export` / `import <file>` | | Save or restore the add-on list as `addons.json` |
| `config get\|set\|unset <key>` | | `github-token` (Keychain; `set` reads from stdin), `default-channel`, `default-install` |
| `cache info\|clear` | | Download, catalogue and support caches |
| `doctor` | | Checks WoW detection, store health, GitHub reachability, rate limit and token |

**`<ref>` can be:** `owner/repo`, a GitHub URL, `github:owner/repo`, or an add-on name such as `addonctl rm bigwigs`.

## Global options

| Option | Meaning |
|---|---|
| `-I, --install <id\|path>` | Which installation to use. Defaults to `config default-install`, then the only Forever install; with several, it asks |
| `--json` | One JSON document on stdout (`"schemaVersion": 1`), no prompts or colour |
| `-y, --yes` | Assume yes. Destructive commands in `--json` or non-terminal mode require it |
| `-q`, `-v` | Quiet / verbose |
| `--no-color` | No ANSI colour (the `NO_COLOR` environment variable works too) |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | General error |
| 2 | Usage error, or an ambiguous ref |
| 3 | Partial failure (some add-ons failed) |
| 4 | Rate limited |
| 5 | Conflict or unmanaged folder (retry with `--force`) |
| 10 | Outdated (`outdated` only) |

## Environment

| Variable | Effect |
|---|---|
| `ADDONS_GITHUB_TOKEN`, then `GITHUB_TOKEN` | Override the Keychain token for this run |
| `ADDONS_DATA_DIR` | Keep all data under this folder and skip WoW auto-detection. Use it for testing |
| `NO_COLOR` | Disable colour |

## Shell completions

```sh
addonctl --generate-completion-script zsh > ~/.zfunc/_addonctl
```

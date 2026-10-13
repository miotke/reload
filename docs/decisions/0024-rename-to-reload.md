# 0024: Rename ForeverAddons to Reload

The app, CLI, bundle ID, Xcode project and GitHub repo are now called Reload, and data from the old name moves across on first launch.

- **Status:** Accepted
- **Date:** 2026-10-12

## Context

"ForeverAddons" tied the product to one game version, though the core supports every flavor ([decision 0016](0016-one-flavor-per-game.md)), and `addonctl` was awkward to type. `/reload` is the command every WoW player types after changing add-ons. Nothing on macOS or in Homebrew installs a `reload` command; an npm live-reload tool does, for people who install it globally.

## Decision

| Was | Now |
|---|---|
| ForeverAddons.app and its bundle ID | Reload.app and a Reload bundle ID (since replaced, [decision 0026](0026-bundle-id-without-personal-name.md)) |
| `addonctl` (`Sources/addonctl`, `addonctlTests`) | `reload` (`Sources/reload`, `reloadTests`); the root command type is `ReloadCLI` |
| `App/ForeverAddons`, `ForeverAddons.xcodeproj` | `App/Reload`, `Reload.xcodeproj`, scheme `Reload` |
| `ADDONS_DATA_DIR`, `ADDONS_GITHUB_TOKEN`, `ADDONS_LIVE_TESTS` | `RELOAD_DATA_DIR`, `RELOAD_GITHUB_TOKEN`, `RELOAD_LIVE_TESTS` |
| github.com/miotke/swift-addons | github.com/miotke/reload |

- **The Xcode CLI target is `reload-cli`** (product `reload`, module `ReloadCLITool`). A target named `reload` shares the app's `Reload.build` folder on a case-insensitive disk and the build fails.
- **`AddonKit` keeps its name.** It doesn't carry the product name.
- **One-time migration** (`LegacyDataMigration`):
  - The app and CLI rename the ForeverAddons folder in `~/Library/Application Support` and the matching Caches folder to the new bundle ID at startup, when the new folder doesn't exist yet. It's a rename on one volume, so it's instant; it never runs with `RELOAD_DATA_DIR`.
  - `KeychainStore.get()` on the default service takes over a token stored under the old service on first read, which is already when the Keychain may be read ([core.md](../architecture/core.md)), so launch never waits on a prompt.
  - The app copies user defaults from the old domain once, without overwriting.
- No `addonctl` alias. The old symlink in `/usr/local/bin` points into the old app and is replaced by installing the CLI again from Settings ▸ Command Line.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep the bundle ID, change only the display name | The folders, defaults domain and Keychain service would keep the old name forever |
| Accept `ADDONS_*` variables as fallbacks | Only development and tests used them; two names for one setting is confusing |
| Satchel, Everbag, AddOn Satchel | "Reload" says WoW add-ons to players without a trademarked word |

## Consequences

- Two quick `fileExists` checks run on every launch; the move itself happens once.
- If the old ForeverAddons app is still running during the move, it keeps writing to files that are now in the new folder. Quit it before launching Reload.
- Decision records before this one were updated to the new names, so their paths still resolve.

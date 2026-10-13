# 0026: Bundle ID without a personal name

The bundle ID is now `io.github.miotke.Reload`, and data under the previous ID moves across on first launch, the same way the ForeverAddons rename did.

- **Status:** Accepted
- **Date:** 2026-10-12

## Context

The repo went public. The bundle ID, the folders named after it and the copyright line all carried the owner's full name. The GitHub username is fine to keep; the full name isn't.

## Decision

| Was | Now |
|---|---|
| App bundle ID with the owner's name | `io.github.miotke.Reload` (`AppInfo.bundleID`) |
| CLI and test bundle IDs, `bundleIdPrefix` | `io.github.miotke.Reload.cli`, `io.github.miotke.ReloadTests`, `io.github.miotke` |
| Copyright holder in `LICENSE` and `NSHumanReadableCopyright` | `miotke` |

- **The ID uses the `io.github.<user>` convention** for projects hosted on GitHub without their own domain.
- **`LegacyDataMigration.legacyBundleIDs` lists every earlier ID, newest first.** That list is the only place the old IDs remain in the source, and only so existing installs can find their data.
  - **Folders:** the first legacy Application Support and Caches folders found are renamed to the new ID when the new ones don't exist yet. Older leftovers are left alone.
  - **Keychain:** `KeychainStore.get()` on the default service takes over the token from the first earlier service that has one, on first read.
  - **Defaults:** the app copies each earlier domain once, newest first, without overwriting. The newest value wins, and older domains only fill gaps.
- Git history keeps the old name. Rewriting published history would break every clone, so it stays.

## Alternatives considered

| Option | Why not |
|---|---|
| Change only the docs, keep the ID | The name stays in every user's Library folders, Keychain and defaults |
| A made-up domain such as `app.reload` | Reverse DNS should point at something the project controls |
| Drop the old data instead of migrating | Every 0.1.x user would lose their installs list, token and settings |

## Consequences

- One more pair of `fileExists` checks at startup, the same as decision 0024.
- macOS treats this as a new app. Privacy prompts and the Keychain access prompt for the moved token can appear again once.
- The CLI symlink in `/usr/local/bin` points into `Reload.app`, whose path didn't change, so it keeps working.

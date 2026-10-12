# 0025: GitHub Releases with optional signing

Releases are zips on GitHub Releases, built by one script that a tag-triggered workflow runs. Developer ID signing and notarization switch on when credentials exist.

- **Status:** Accepted
- **Date:** 2026-10-12

## Context

Reload isn't going on the Mac App Store: it writes into the WoW folder and installs a CLI symlink, which the sandbox forbids, and the owner doesn't want it there. Signing needs the paid Apple Developer Program, which isn't set up yet, but the release pipeline shouldn't wait for it.

## Decision

- **`scripts/release.sh <version>`** archives the Release configuration, verifies the signature of the app and the bundled CLI, optionally notarizes and staples, then zips with `ditto` and writes a SHA-256 file.
- **Signing is driven by environment variables** (`RELOAD_TEAM_ID`, notary profile or API key). With none set, the build is ad-hoc signed, like Debug. `project.yml` stays ad-hoc so anyone can clone and build without an Apple account.
- **The version is checked, not stamped.** The script fails when the tag differs from `Info.plist`, `project.yml` or `AppInfo.version`, so every release matches a commit.
- **`.github/workflows/release.yml`** runs on `v*` tags: `swift test`, the script, then a **draft** release for a human to publish. Certificates go into a temporary keychain that's deleted at the end.
- Details: [app/releases.md](../app/releases.md).

## Alternatives considered

| Option | Why not |
|---|---|
| Mac App Store | Sandbox blocks writing to the WoW folder and the CLI symlink |
| Stamp the version from the tag at build time | The built app could carry a version no commit has |
| Publish releases automatically | A draft lets the notes and the zip be checked first |
| fastlane | A Ruby toolchain for three `xcodebuild`/`notarytool` calls |
| DMG instead of zip | Needs its own signing and notarization step; a zip is enough to start |

## Consequences

- Until signing is set up, people must right-click ▸ Open the first time, and the release notes say so.
- Bumping a version means editing three files.
- The CI job depends on GitHub's runner having Xcode 27; it fails clearly when it doesn't.
- No auto-update yet.

# 0000: Original design

The original design doc, trimmed: goals, non-goals, sources researched, open questions and milestones.

> **Historical; current behaviour lives in the topic docs.** Written 2026-10-11 before any code existed. Start at [docs/README.md](../README.md) for how things work today. Parts of the original that are still true were moved into the topic docs; choices it made are recorded as decisions [0001](0001-swift-package-core.md)–[0006](0006-bundled-cli-install.md).

- **Status:** Superseded by 0001–0014 and the topic docs
- **Date:** 2026-10-11

## Goals

- **Native Mac app.** SwiftUI app with a small, testable Swift core underneath it.
- **Forever first.** Every decision is checked against how Forever is packaged. Other game versions should be easy to add later, but aren't a v1 goal.
- **Find add-ons, not just manage them.** Search covers installed add-ons, a catalogue of GitHub-hosted add-ons and live GitHub, and shows whether each result supports Forever.
- **No gatekept APIs.** Only sources that need no developer key. Users may paste their *own* GitHub token. The app never ships a secret.
- **Safe on disk.** Never leave `Interface/AddOns` half-written, never delete a folder it didn't install without asking, never write outside `Interface/AddOns`.

## Non-goals (v1)

- CurseForge and Wago (both need keys).
- Building add-ons from source, or installing from tags, zipballs or tarballs.
- Managing WeakAuras or other SavedVariables data.
- Windows or Linux.

## Sources researched

| Source | Key needed | Plan | Notes |
|---|---|---|---|
| GitHub Releases | No (optional user token) | v1, primary | Where most big add-ons publish (BigWigs, DBM, WeakAuras, Details, Plater, BugSack, …) |
| GitHub catalogue | No | v1, for search | `layday/github-wow-addon-catalogue` `addons.csv`, ~2.4k repos, raw file. Its `flavors` column under-reports Forever |
| WoWInterface | No | v2 | `api.mmoui.com/v3/game/WOW/filelist.json` and `filedetails/{id}.json`. The file list includes game-version data, so it could report Forever support directly. TOCs carry `X-WoWI-ID` hints for adopting |
| Tukui | No | v2 | `api.tukui.org/v1/addons` (ElvUI, Tukui) |
| CurseForge | Yes, granted by Overwolf at its discretion | no | Would need a small proxy so the key isn't shipped. Would enable fingerprint matching (`POST /v1/fingerprints`) for adopting |
| Wago Addons | Yes, a Bearer token given to users through Wago's Patreon | no | Could let users paste their own token, as instawow does |

Decision: [0002](0002-github-releases-no-keyed-apis.md).

## Other add-on managers

- **[instawow](https://github.com/layday/instawow)** (Python): the design borrows heavily from its source. Its author also maintains the GitHub catalogue. Ideas noted: user-supplied Wago tokens, and reading only a zip's file listing with an HTTP `Range` request on the last ~25 KB.
- **[WowUp](https://github.com/WowUp/WowUp)**: the other main influence, credited in the root README.
- **[BigWigs packager](https://github.com/BigWigsMods/packager)**: the source of `release.json` and the TOC suffix rules.

## Ideas that didn't ship (yet)

- Security-scoped bookmarks per installation, so the App Sandbox could be enabled later. v1 was planned as Developer ID, notarized, not sandboxed.
- Sparkle self-updates; a Homebrew tap for `addonctl`.
- Range-request zip inspection.
- Warning when a `RequiredDeps` add-on is missing.
- `FlavorRules` entries for mainline and classic.
- Category chips defined in a bundled JSON file (they ended up in `SearchAliases.swift`).

## Open questions (at the time)

1. Forever's launch folder and product code. Currently `_classic_beta_` / `wow_classic_beta`; detect by game version so it keeps working.
2. App name and bundle id: `ForeverAddons` / `com.andrewmiotke.ForeverAddons` were placeholders.
3. Contribute Forever tags back to the catalogue, or keep our own list of known Forever repos?

## Original milestones

1. **M0 – Core parsing:** package scaffold; `Toc`, `ReleaseJSON`, `BuildInfo`, `FlavorRules`, with tests.
2. **M1 – Resolve:** `GitHubSource` and `ReleaseSelector`; `addonctl resolve` works for BigWigs and DBM.
3. **M2 – Install + CLI:** `Downloader`, `Installer`, `InstallStore` (with locking), `InstallationLocator`, `AddonManager`; core `addonctl` commands with `--json` and exit codes.
4. **M3 – App shell:** installations sidebar, Installed list, Update All.
5. **M4 – Search & adopt:** catalogue and installed search, Forever verification, live GitHub search, Browse, adopting, settings and Keychain token.
6. **M5 – Polish:** rollback, `export`/`import`, `doctor`, completions, bundling the CLI in the app, menu bar extra, notarized build.

## References

- GitHub REST API (releases): https://docs.github.com/en/rest/releases
- TOC format: https://warcraft.wiki.gg/wiki/TOC_format

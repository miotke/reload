# 0002: GitHub Releases as the primary source, no keyed APIs

Add-ons come from GitHub Releases, with the community GitHub catalogue for search; sources that need a developer key are out.

- **Status:** Accepted
- **Date:** 2026-10-11

## Context

Add-ons are published to several hosts. Most popular ones are built by the BigWigs packager, which uploads the same zip to CurseForge, Wago, WoWInterface and (when enabled) GitHub Releases, together with a `release.json` describing it.

The hosts differ in access:

| Host | Access |
|---|---|
| GitHub Releases | Public API, no key. 60 calls/h per IP without a token, 5,000 with a user's own token |
| GitHub catalogue (`layday/github-wow-addon-catalogue`) | A raw CSV on `raw.githubusercontent.com`, no quota |
| WoWInterface | Keyless JSON (`api.mmoui.com/v3/game/WOW/filelist.json`) |
| Tukui | Keyless JSON (`api.tukui.org/v1/addons`) |
| CurseForge | Needs an API key that Overwolf grants at its discretion; the key would have to be hidden |
| Wago | Needs a key users get through Wago's Patreon |

## Decision

- **GitHub Releases is the primary source.** BigWigs, DBM, WeakAuras, Details, Plater, BugSack and others publish there.
- **The GitHub catalogue powers search** (~2.4k repos, one raw download per day).
- **No keyed APIs.** The app never ships a secret. Users may add their *own* GitHub token (Keychain or `ADDONS_GITHUB_TOKEN`) to raise rate limits.
- **WoWInterface and Tukui are keyless candidates for later**, as more `Source` implementations. The `github:` ref prefix leaves room for them.

## Alternatives considered

| Option | Why not |
|---|---|
| CurseForge | Key granted by Overwolf, and shipping it in an open app would leak it. A proxy server would be needed |
| Wago | Every user would need a Patreon-issued key |
| Scraping host websites | Fragile, and against their terms |

## Consequences

- Add-ons published only to CurseForge or Wago can't be installed.
- The GitHub API quota is the main constraint, which drove the quota-free endpoints ([0010](0010-quota-free-endpoints.md)) and local-first search ([0009](0009-local-first-search.md)).
- Forever support has to be worked out from `release.json` or the zip itself ([0003](0003-forever-detection.md)), because the catalogue's `flavors` column under-reports Forever.

## See also

- [network/github-endpoints.md](../network/github-endpoints.md)
- [0000-original-design.md](0000-original-design.md) for the source research

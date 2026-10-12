# Release selection

How `GitHubSource` finds the newest GitHub release of an add-on that supports the installation's flavor (Forever, Retail or a classic game), and the right zip within it. Examples use Forever.

Code: `Sources/AddonKit/GitHub/GitHubSource.swift`, `GitHubModels.swift`, `Selection/ReleaseSelector.swift`, `Selection/ZipInspector.swift`. Why `release.json` first: [decision 0003](../decisions/0003-forever-detection.md); per-flavor rules: [decision 0016](../decisions/0016-one-flavor-per-game.md). The requests it makes: [github-endpoints.md](../network/github-endpoints.md).

## How a release is chosen

```mermaid
flowchart TD
    A[GET /repos/owner/repo/releases?per_page=10] --> B[Drop drafts<br/>drop prereleases unless channel = prerelease]
    B --> C{Next release,<br/>newest first}
    C --> D{Has release.json?}
    D -- yes --> E[Download release.json<br/>no API quota]
    E --> F{Full build naming<br/>the flavor?}
    F -- yes --> G[Pick the asset<br/>named in filename]
    F -- no --> C
    D -- no --> H[Candidate zips:<br/>uploaded .zip, not -nolib]
    H --> I[Download and run ZipInspector]
    I -- supports the flavor --> G
    I -- no match --> C
    C -- none left, or 3 zip<br/>inspections used --> X[noCompatibleRelease]
```

- Walking back to older releases handles authors who dropped support for a game: users stay on the last build that works.
- `ReleaseSelector` is pure and synchronous. When it needs data it doesn't have yet, it returns `.needsReleaseJSON` or `.needsInspection`. `GitHubSource` fetches that data and asks again, adding releases whose zips didn't match to an exclusion list.
- **`release.json` names per flavor:** a build counts when its metadata lists one of the flavor's names, e.g. `forever` or `camelot` for Forever, `classic` or `vanilla` for Classic Era, `bcc` or `tbc` for TBC ([flavors.md](../architecture/flavors.md#flavors)).
- `noCompatibleRelease` shows as "No <flavor> build yet" in the app, using the flavor's display name.

## Reasoning trail

Every `ResolvedRelease` carries a `reasoning` trail, for example:

```
["release v426.4 (id 123)", "release.json → BigWigs-v426.4.zip (forever 16001)"]
```

`addonctl resolve` and `addonctl info` print it ([cli/commands.md](../cli/commands.md)).

## ZipInspector: does a zip support the flavor?

It uses the TOC file the game client itself would load:

1. Find add-on folders: a top-level folder `F` containing `F/F[suffix].toc`. `__MACOSX/` is ignored.
2. **A TOC with one of the flavor's own suffixes decides on its own** (`_Camelot` or `-Forever` for Forever, `_Mists` for Mists Classic): supported.
3. Otherwise the **first shared TOC in the flavor's order** is used (`_Mainline` for Forever; `_Classic` for the classics; `_Wrath`, `_WOTLKC`, then `_Classic` for Titan), then the base TOC.
4. That TOC counts only if one of its `## Interface:` values is in the flavor's ranges (16000–19999 for Forever). So `_Mainline` supports Forever only with a `16xxx` interface, and `_Classic` supports exactly the classic game its interface belongs to.

The same check runs on an add-on folder already on disk, which adopting uses. Suffixes and ranges come from [FlavorRules](../architecture/flavors.md).

## Quota-free resolve (stable channel)

`AddonManager.resolve` (stable channel) and stable update checks first ask `GitHubSource.latestRelease` for the latest release. When its `release.json` names a build for the flavor, the release is resolved without the API. The download URL is built as `github.com/{owner}/{repo}/releases/download/{tag}/{filename}`, so installing or updating BigWigs, DBM and other packager-built add-ons costs no API quota. Why: [decision 0010](../decisions/0010-quota-free-endpoints.md).

- It returns nil, and the caller falls back to the API flow above, when the latest release has no `release.json` or lacks the flavor (an older release might still have it).
- Such a release has no real release ID or date: `releaseID` is a negative hash of `owner/repo@tag` and `publishedAt` is the time of the check. `InstalledAddon.isUpdate` compares **tags** whenever either side has a synthetic ID, so a re-resolve never shows a false "update available".
- The prerelease channel always uses the API: `releases/latest` excludes prereleases.

## Inspection limits

- At most 2 candidate zips are inspected per release without a `release.json`, and at most 3 releases.
- Inspected zips are saved at the `Downloader`'s archive path, so the install reuses them and pruning cleans them up ([installing.md](installing.md#downloader)).

## Support checks

`check(_:flavor:policy:background:)` (and `support(for:flavor:)`, the `SupportChecking` protocol) costs **no API quota**. It looks only at the latest stable release:

```mermaid
flowchart LR
    A[HEAD releases/latest] -- 302 to releases/tag/T --> V{Stored verdict<br/>made against T?}
    V -- yes --> R[reuse it]
    V -- no --> B[GET releases/download/T/release.json]
    A -- 302 to /releases --> N[.noReleases]
    A -- 404 --> N
    B -- has forever --> S[.supported version: T]
    B -- other flavors only --> U[.unsupported]
    B -- 404 --> D[.needsDownload]
```

| Outcome | `SupportStatus` |
|---|---|
| Latest release's `release.json` lists the flavor | `.supported(version: tag)` |
| It lists only other flavors | `.unsupported` |
| Latest release has no `release.json` | `.needsDownload` |
| No releases, or the repo is gone | `.noReleases` |
| Anything else failed | `.unknown` (stored as an `error` row, never shown) |

- Alongside the verdict, `LatestRelease` and `SupportCheck` carry `availableFlavors`: every flavor the release's `release.json` names, nil without one. It's stored per repo in `repo_meta` (`available_flavors`, `flavors_tag`, `flavors_source`) in the verdict's transaction; another flavor's check reuses it, and a stored `release.json` without it is derived locally. For a release with no `release.json`, an installed or adopted zip's TOCs fill it in (source `inspection`, which never replaces a `release.json` answer). `SupportStatus` stays as is for install logic.

- `GitHubSource` is the **only owner** of verdicts and latest tags; callers pass a `CachePolicy` and never judge freshness themselves ([decision 0011](../decisions/0011-single-cache-owner.md)). How long each outcome is reused: [caching.md](../network/caching.md#lifetimes).
- Concurrent lookups for the same repo and flavor share one request.
- If github.com fails for a reason other than pushing back (429/403), `apiSupport(for:flavor:)`, the API path, answers while quota is comfortable. It also looks past the latest release, and keeps a 10-call reserve.
- `background: true` requests stay off constrained (Low Data Mode) networks.

## Retail build on Forever

Forever loads the `_Mainline` family TOC, so a Retail build often works there ([flavors.md](../architecture/flavors.md#game-families)). It's offered, never chosen silently:

- `resolve(_:for:channel:allowFamilyFallback:)` and `install(…, allowFamilyFallback:)`: when the installation's flavor has no build and `allowFamilyFallback` is true, the `Flavor.fallbackFlavor` build (`mainline` on Forever) is resolved the usual way, quota-free first. `ResolvedRelease.flavorBuild` marks it and its reasoning says so. Without the flag, or with no fallback build either, it's `noCompatibleRelease`.
- The install records `InstalledAddon.installedFlavorBuild = .mainline` (and keeps it in rollback snapshots).
- **Update checks keep to that build.** They first ask whether the latest release now has a build for the installation's own flavor; if so, that's the update ("Forever build available"), even for the same tag, and installing it clears `installedFlavorBuild`. Otherwise they check the Retail build as usual. `isUpdate` treats a change of build as an update.
- An add-on installed as its own build never switches: if a release drops Forever, the check says `noCompatibleRelease` or stays on the last Forever release.
- App: **Install Retail Build…** with a confirmation; CLI: `addonctl install --retail-build`.

## Parsing refs

`parse(_:)` accepts:
- `owner/repo` and `github:owner/repo`
- `https://github.com/owner/repo`, with or without `www.`, `.git` or a trailing slash
- repo URLs ending in `/releases…`, `/tags`, `/tree/…` or `/blob/…`

Case is preserved. Name lookup (`AddonManager.lookup`) is described in [core.md](../architecture/core.md#behaviour-worth-knowing).

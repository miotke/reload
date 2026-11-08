# Optional parts

Extra add-ons that a managed add-on can use and that its own GitHub repo publishes as a separate release stream. Spoken's voice packs are the example, but nothing here is specific to Spoken.

Contract: `AddonManaging.optionalParts(of:in:policy:)`, `OptionalPart` (`Sources/AddonKit/Model/OptionalParts.swift`) and `AddonRef.tagPrefix`. Code: `AddonManager+OptionalParts.swift`, `GitHub/LatestReleaseStore+Listing.swift`, `Selection/ReleaseStreams.swift`.

## The shape it handles

One repo, several add-ons, told apart by tag prefix (the part of a tag before its first `/`):

| Tag | Zip | What it is |
|---|---|---|
| `spoken/v3.8.4` | `Spoken-3.8.4.zip` | the add-on and its modules |
| `places-audio/v2.1.0` | `SpokenPlacesAudio-2.1.0.zip` | a voice pack, 435 MB |
| `zones-audio-deDE/v2.1.1` | `SpokenZonesAudio_deDE-2.1.1.zip` | a language pack |
| `manager/v0.1.12` | `.dmg`, `.AppImage`, `…-mac-arm64.zip` | a desktop app, not an add-on |

The add-on's TOC names the parts it can use: `Spoken_Places.toc` has `## OptionalDeps: SpokenPlacesAudio`. The real repo has about 143 releases in 45 prefixes, so its packs sit far apart in the list.

## The rule

1. Read the loaded TOCs of the managed add-on's folders (the same rule as [dependencies](dependencies.md#detection)) and take their `OptionalDeps`, minus its own folders and `Blizzard_*`.
2. Read the repo's [release listing](#the-release-listing); none with `.preferStored` and nothing stored.
3. A folder becomes a part when exactly one tag prefix's latest stable release has a zip whose name starts with the folder name followed by `-` or `_` (case-insensitive). A name that continues with a version (`SpokenZonesAudio-2.0.1.zip`) beats one that continues with anything else (`SpokenZonesAudio_deDE-…`, a language pack). Two equally good streams mean no part: guessing could install the wrong 1 GB pack. The add-on's own stream never counts.
4. The part's ref is the repo plus that `tagPrefix` (`owner/repo#places-audio`); `version` is that release's tag and `downloadSize` the zip's size.
5. State: `installed` (managed as that ref), `unmanaged` (the folder is in `AddOns/`; `adopt(folder:as:in:progress:)` it), or `available`. A folder another managed add-on owns isn't offered.

Parts are never installed without the user choosing them.

## The release listing

`LatestReleaseStore.listing(for:flavor:policy:background:keepReserve:)` owns it, beside the latest tags it's checked against ([decision 0011](../decisions/0011-single-cache-owner.md)). Stored in `release_listing`, one row per repo.

- **Request:** `GET /repos/{owner}/{repo}/releases?per_page=100`, page 1 with its ETag, then up to 2 more pages while `Link` says `rel="next"`. 1–3 API calls; a later page failing keeps what was read.
- **Kept:** releases with a prefix, per prefix the newest 3 stable and 2 prereleases, no drafts, notes capped at 4,000 characters: about 1 KB per release instead of the API's 6.
- **Freshness:** current while the repo's latest stable tag (quota-free `releases/latest`, under the caller's policy) is the one it was fetched with. A new stable release in *any* stream moves that tag, so an unchanged repo costs no API call. When github.com doesn't answer, `.revalidateIfStale` keeps a listing under 6 hours old.
- **Failures:** kept beside the last good listing and retried after 15 minutes; a 404 after 24 hours. With nothing stored, the first failure throws.
- **Quota:** the inspector and background checks pass `keepReserve`, so no listing call is made within 10 calls of the limit. Rate-limit state is `GitHubAPIClient`'s.
- Concurrent callers for one repo share one fetch. Prereleases of a stream appear when the listing is next fetched.

## Resolving a stream

A ref with a `tagPrefix` only ever resolves, checks and updates within `<prefix>/…` tags (`GitHubReleaseResolver.resolve(_:within:prefix:…)`, over the listing):

- A release with a `release.json` is chosen as usual ([release selection](release-selection.md)).
- Without one, a zip is taken **without downloading it** when the stream leaves no doubt: the successor of the installed zip (same name but for the version), or the release's only zip. Other zips are inspected only by explicit actions, never above 200 MB.
- `releases/latest` is repo-wide, so it decides only one thing for a stream: when it *is* the installed tag, nothing newer exists anywhere and the add-on is up to date for free.
- Support verdicts, details and release notes of a prefixed ref come from its stream in the listing, not from the repo's latest release. Catalogue rows, READMEs and stars belong to `ref.repo`.

## The whole repo

The plain ref (`owner/repo`) stays what it was, but an installed one **follows the stream of its installed tag** (`ReleaseStreams.followedPrefix`): Spoken installed at `spoken/v3.8.4` only ever updates to `spoken/…`, never to `manager/…` or a pack. The record isn't migrated to a prefixed ref, so catalogue rows and search still match it by `owner/repo`.

A plain ref that isn't installed resolves over the whole repo, but a release that ships a desktop installer (`.dmg`, `.exe`, `.AppImage` …) is skipped, and zips named for a platform (`-mac-arm64`) are never candidates: the 140 MB app zip is never downloaded to look inside. `lookup` by repo name picks the add-on over its parts.

## Large downloads

Parts are 0.4–1.6 GB ([installing.md](installing.md#large-downloads)): downloads stop past 4 GB, extraction allows twice the zip's size, and an archive over 256 MB is cached alone (no rollback copy). A part's zips live in their own cache folder (`owner+repo+prefix`), so they never prune the add-on's.

## Network cost

Opening the inspector of a Spoken-like add-on, unauthenticated:

| Case | Requests |
|---|---|
| First time | 1 HEAD `releases/latest` (if its verdict is over an hour old) + 1–3 API calls for the listing |
| Again, latest tag unchanged | 0 (HEAD only once the verdict is over an hour old) |
| After a release in any stream | 1 HEAD + 1 API call (a 304 if page 1 didn't change) |
| `.preferStored` | 0 |

Update checks of the add-on and its installed parts share one listing; an unchanged latest tag costs one HEAD each and no API call ([budget.md](../network/budget.md#optional-parts)).

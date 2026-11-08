# 0031: Tag streams and optional parts

One GitHub repo can hold several add-ons, told apart by tag prefix, and Reload offers an add-on's `OptionalDeps` that its own repo publishes as their own stream.

- **Status:** Accepted
- **Date:** 2026-11-08

## Context

WoW Forever launched, and Spoken's voice packs couldn't be installed. `rusty-key/spoken-wow` publishes about 45 streams from one repo: `spoken/v3.8.4` (the add-on), `places-audio/v2.1.0` (`SpokenPlacesAudio-2.1.0.zip`, 435 MB), quest audio up to 1.4 GB, language packs, and desktop apps (`manager/…`, with a 140 MB `-mac-arm64.zip`). Reload treated a repo as one add-on and took its newest release. So the packs were unreachable, and plain Spoken could have updated to `manager/…` or downloaded the Manager zip to inspect it. The packs are on CurseForge too, which Reload can't use ([decision 0002](0002-github-releases-no-keyed-apis.md)).

`Spoken_Places.toc` lists `## OptionalDeps: SpokenPlacesAudio`, and each pack's zip is named after its folder. Nothing about this is Spoken-specific.

## Decision

- **`AddonRef.tagPrefix`**: `owner/repo#places-audio` follows only `places-audio/…` tags. `AddonRef.repo` drops it for catalogue rows and READMEs. `isSameAddon(as:)` compares streams; `isSameRepo(as:)` stays repo-level.
- **Optional parts**: a loaded TOC's `OptionalDeps` folder is a part when exactly one stream's latest stable release has a zip named after it. They're never installed without the user choosing, in the inspector or with `reload install --with-optional`.
- **One owner for the release listing**: `LatestReleaseStore`, stored in `release_listing` (migration 8). `releases?per_page=100`, up to 3 pages, with an ETag. It stays current while the repo's quota-free `releases/latest` tag is unchanged, so an unchanged repo costs no API call.
- **Plain refs follow their installed tag's prefix** (`ReleaseStreams.followedPrefix`) instead of being migrated. Fresh installs skip releases that ship desktop installers and never inspect platform-named zips.
- **Big downloads**: the download cap went from 200 MB to 4 GB. Extraction limits scale with the zip, and an archive over 256 MB is cached alone.

## Alternatives considered

| Option | Why not |
|---|---|
| Point users at CurseForge | Needs a key Reload can't ship (0002) |
| Encode the prefix in `identifier` | Every `owner/repo` split would break silently |
| Migrate plain records to `tagPrefix` | Catalogue, search and the app match them as `owner/repo` |
| Read packs' `X-Child-Of` | Not a standard field; `OptionalDeps` is the game's own |
| Keep `per_page=10` | Interleaved streams push a pack's release past page 1 |

## Consequences

- Any repo that publishes optional add-ons as their own streams works, not just Spoken.
- Opening such an add-on costs 1–3 API calls the first time and none while nothing is released ([network/budget.md](../network/budget.md)).
- Parts over 256 MB have no rollback zip; repair downloads them again.
- Not covered: a part installed as another game's build never switches back, a stream's prereleases only show after the next listing fetch, and slash-tag `release.json` URLs haven't been checked against live GitHub.

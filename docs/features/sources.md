# Add-on sources

Where add-ons come from (GitHub, WoWInterface, Tukui), how the two hosted sources work without per-game metadata, and what turning a source off does.

Code: `Sources/AddonKit/AddonManager+Sources.swift`, `Sources/AddonKit/Sources/` (`HostedSource`, `WoWInterface`, `Tukui`, `HostedCatalogue`, `SourceSettings`). Why: [decision 0029](../decisions/0029-wowinterface-and-tukui-sources.md).

## The sources

| Source | Listing | Latest file | Refs |
|---|---|---|---|
| GitHub | the community catalogue CSV ([search.md](search.md)) | releases, `release.json` ([release-selection.md](release-selection.md)) | `owner/repo`, `github:owner/repo`, `github.com` URLs |
| WoWInterface | `api.mmoui.com/v3/game/WOW/filelist.json`: ~8,200 add-ons, ~5.6 MB | `…/filedetails/<id>.json`: download link, MD5 (checked by the [downloader](installing.md#downloader)), description (BBCode), changelog | `wowinterface:3826`, `wowinterface.com/downloads/info3826-…`, `…/fileinfo.php?id=3826`, `…/download3826-…` |
| Tukui | `api.tukui.org/v1/addons`: ElvUI and Tukui, a few KB | the same listing, which carries the download link | `tukui:elvui`, `tukui.org/elvui` |

All three are keyless. WoWInterface and Tukui are **hosted sources** (`HostedSource`): one listing of every add-on and one zip per add-on, with no builds per game and no prereleases. Both channels get the latest file.

## Keys

`AddonRef.key` is how a ref is stored and shown: `owner/repo` for GitHub, `wowinterface:3826` / `tukui:elvui` for the others. GitHub names can't contain a colon, so keys never collide, and `AddonRef(key:)` reverses one.

- Every metadata table keyed by `full_name` (`catalogue`, `repo_meta`, `release_folders`, `hosted_files`) uses the key. For GitHub rows that's the same `owner/repo` as before, so no data moved.
- Hosted listings go into `catalogue` with `source` set to the host (`wowinterface`, `tukui`), plus `author`, `screenshots_json` and `folders_json` (WoWInterface's `UIDir`, Tukui's `directories`: the folders each download ships, for [missing dependencies](dependencies.md#candidates)). GitHub rows keep `catalogue` / `github_search`.
- Hosted add-ons never get `support` rows. The refresh's verdict queries only ever see GitHub repos.

## Which games a hosted file supports

Hosts don't say whether a file supports Forever. WoWInterface lists the game versions the author ticked (often stale); Tukui lists patches. Neither has a Forever version.

- **Listing flavors** (`CatalogueEntry.listedFlavors`, from `Flavor.from(gameVersion:)`) give search and Browse their R / C letters until something better is known. With only those, a hosted result's support is `.needsDownload`.
- **The zip decides.** Resolving (install, update, adopt preview, `reload resolve`) downloads the zip into the download cache, which the install then reuses, and reads its TOCs with `ZipInspector`, the same rule as a GitHub release without a `release.json`. The flavors it ships are stored as an `inspection` in `repo_meta`, so search shows `F` from then on.
- No Forever TOC: `noCompatibleRelease`, and with `allowFamilyFallback` the Retail build ([release-selection.md](release-selection.md#retail-build-on-forever)).

## Freshness

`HostedCatalogue` is the single owner of hosted data ([decision 0011](../decisions/0011-single-cache-owner.md)).

| Data | Trusted for | Then |
|---|---|---|
| A listing | 24 h (`maxAge`); 15 min after a failure (`failureBackoff`) | Downloaded again by the refresh, or `force` (⌘R, `reload refresh --force`). `If-None-Match` when the host sent an ETag (neither does today) |
| A latest file | 1 h (`fileTTL`), like a GitHub verdict | `.revalidateIfStale` asks again; `.forceRevalidate` always asks; `.preferStored` uses any stored file |
| Details | 24 h (`detailsTTL`), like a README | The latest file is asked for again |

- **Search never waits for a listing.** One that's on but was never downloaded (`missingListings`, outside the 15-minute failure backoff) is fetched by the next `refresh`, even inside its 2-hour window, as a catalogue phase step ("Downloading the WoWInterface add-on list…") that the sidebar's progress shows. Turning a source on in the app starts that refresh; when the rows land, Browse re-runs the search. The CLI's `search` downloads it first, behind a spinner, since a terminal waits anyway.
- Tukui's file lookup is the listing itself, so one request stores both add-ons' files.

## Updates

Bulk checks (the refresh, ⌘R, `reload outdated`) and Update All first fetch every due hosted add-on's latest file together (`HostedCatalogue.prefetch`): WoWInterface's `filedetails/101,102,….json` takes up to 50 IDs per request (`batchSize`), and Tukui's listing has them all. Each check then reads that fresh answer. An add-on the batch missed is asked for on its own.

`hostedUpdateState`: the latest file's version against the installed one (`isUpdate`; hosted releases have synthetic IDs, so versions are compared). Same version: up to date, no download. New version: its zip is downloaded and inspected for the build in use, then offered. On a Retail build on Forever, a new version with a Forever TOC is offered as the Forever build.

## Turning sources on and off

Settings ▸ Sources in the app, `reload sources enable|disable <source>` in the CLI. Stored in `source_settings` in the metadata database, so both share it; no row means on. Changing it is reported as a `.catalogue` change, so Browse reloads.

A source that's **off**:
- adds nothing to search or Browse: no catalogue rows, no direct-ref result, no Popular rows; for GitHub, no live search either;
- downloads no listing during the refresh; with GitHub off, the refresh checks verdicts for installed GitHub add-ons only;
- **doesn't touch installed add-ons**: they stay in the list, show up in search as installed, and keep getting update checks and updates;
- still installs on an explicit ref (`reload install wowinterface:3826`), since that isn't a search.

## Details

`hostedDetails`: name and author from the listing or file, the description as the README (WoWInterface's BBCode turned into Markdown by `BBCode.markdown`; Tukui's is Markdown), screenshots from the listing (WoWInterface) or the gallery (Tukui), the changelog as release notes, and the host's page as the website. No stars or topics.

## In the app

- Browse rows and the inspector name a hosted add-on's source under its name: "by Elv · Tukui" (`AddonByline`). GitHub rows keep "by owner".
- The inspector's link goes to the host's page, labelled with the source.
- Changing Settings ▸ Sources re-runs the current search (`AppModel.enabledSources` is part of Browse's query key) and reloads the home lists.

## Not done yet

- Tukui's changelog (`changelog_url`) isn't fetched; its release notes are empty.
- The same add-on on GitHub and a host shows as two rows. Adoption suggestions are still GitHub-only.

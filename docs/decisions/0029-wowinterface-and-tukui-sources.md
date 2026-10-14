# 0029: WoWInterface and Tukui as sources, switchable per source

WoWInterface and Tukui join GitHub as add-on sources through their keyless APIs; each source can be turned off for search and Browse without touching installed add-ons.

- **Status:** Accepted
- **Date:** 2026-10-14

## Context

[Decision 0002](0002-github-releases-no-keyed-apis.md) made GitHub Releases the only source and named WoWInterface and Tukui as keyless candidates for later. Many add-ons are published only on WoWInterface (~8,200 files), and ElvUI's home is Tukui. Players want to choose which hosts they browse.

Neither host says whether a file supports Forever: WoWInterface lists author-ticked game versions, Tukui lists patches, and neither has a Forever version.

## Decision

- **Hosted sources** (`HostedSource`): one listing per host stored in `catalogue` under `AddonRef.key` (`wowinterface:3826`), and the latest file per add-on in `hosted_files`. `HostedCatalogue` owns their freshness: listings 24 h, files 1 h.
- **The zip decides Forever support**, as for a GitHub release without a `release.json`: resolving downloads it (the install reuses the cached copy) and `ZipInspector` reads the TOCs. Listing game versions only fill the R / C letters until then.
- **One key format** for every metadata table: `owner/repo` for GitHub (unchanged, so no data migration), `source:id` for the others.
- **Per-source switch** in `source_settings`, shared by the app and CLI. Off means no search, Browse or live-search results and no listing downloads; installed add-ons keep update checks.

## Alternatives considered

| Option | Why not |
|---|---|
| A separate table and search index per host | Two search paths to rank and merge; the catalogue table already has a `source` column |
| Keying hosted rows by bare ID (`3826`) | Unambiguous today only by accident of format; `source:id` is explicit and reversible |
| Trusting the listing's game versions for Forever | They never name Forever and are often stale; a wrong "no Forever build" would hide working add-ons |
| Turning a source off also stops update checks | Players would silently stop getting fixes for what they have installed |
| Per-add-on `filedetails` for the whole WoWInterface catalogue | ~8,000 requests; the 5.6 MB listing is one |

## Consequences

- A forced refresh costs two more requests (both listings); a refresh within 24 h costs none ([budget.md](../network/budget.md)).
- The first search with WoWInterface on downloads 5.6 MB once.
- Hosted results show "Retail build only" until opened or installed, even when the zip has a Forever TOC (ElvUI does).
- Add-ons on both GitHub and a host appear twice.

## See also

- [features/sources.md](../features/sources.md)

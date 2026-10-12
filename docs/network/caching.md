# Caching

What is cached, for how long, how ETags and failures are handled, and the single-owner rule with `CachePolicy`.

## Rules

- **Cache everything, failures included**, with a TTL. A repo that 404s or has no Forever build is remembered too.
- **Use ETags** for anything that can change. Send `If-None-Match`; a 304 means the stored copy is current.
- **Never refetch what's stored and fresh.**
- **One owner per kind of remote data** decides freshness. Nobody else keeps a second cache.

## Owners and `CachePolicy`

Why: [decision 0011](../decisions/0011-single-cache-owner.md).

| Data | Owner | Stored in |
|---|---|---|
| Support verdicts (per repo and flavor), latest tags, failures | `GitHubSource` (`latestRelease` / `check`, through `SupportCache`) | `support`, `repo_meta` tables |
| Decoded `release.json` by `repo@tag` | `GitHubSource` | `release_json` table, plus memory |
| Last API call per repo (the 6 h throttle) | `GitHubSource` (`apiCheckIsDue`) | `repo_meta.api_checked_at`, `api_checked_tag` |
| Catalogue | `CatalogueSource` | `catalogue`, `catalogue_state` |
| Inspector details, release notes by tag | `AddonManager.details`, `releaseNotes` | `details` |
| Live search answers | `SearchCoordinator` | `search_cache` |
| Rate-limit state | `GitHubSource` (`core`), `GitHubSearchProvider` (`search`) | `rate_limit` |
| Downloaded zips | `Downloader` | `<caches>/downloads/` |
| Screenshot bytes | `ScreenshotLoader` (app) | its own `URLCache` in `<caches>/screenshots/` |

For support and tags, callers state intent; the owner decides whether to hit the network:

| `CachePolicy` | Network | Store |
|---|---|---|
| `.preferStored` | never | read only; `.unknown` if nothing is stored |
| `.revalidateIfStale` | only when the stored answer is past its lifetime (below); a latest tag any flavor stored under 1 h ago is reused without a request | writes what it learns |
| `.forceRevalidate` | always asks for the latest tag; still reuses the stored verdict when the tag is unchanged | writes what it learns |
| API release list, any policy | bulk and background checks (⌘R, the 2-hour refresh, `outdated`, Update All) ask at most every 6 h per repo, unless the free latest tag changed, and reuse the last stored update state meanwhile. An explicit single-add-on action (install, updating one add-on) always asks | records `api_checked_at` |

Callers never pass `maxAge: 0`-style flags or `reuse: false`, and never call the raw lookups around the owner. Which caller uses which policy: [decision 0011](../decisions/0011-single-cache-owner.md#who-uses-which-policy).

## Lifetimes

A stored verdict is **shown** as long as it's stored. These lifetimes only decide when `.revalidateIfStale` checks again.

| What | Lifetime |
|---|---|
| Verdict: supported, unsupported, needs download | 1 h |
| Verdict: no releases / repo gone (negative) | 24 h |
| Failed check | `error_at` / `retry_after` beside the last good verdict, which keeps showing; retried after 15 min. With no verdict yet the answer is `.unknown`, and no status is stored. Background checks never fall back to the API |
| Latest tag, across flavors | 1 h: another flavor's check reuses it, so only that flavor's verdict (from the stored `release.json`) is needed |
| Catalogue | 24 h, revalidated with ETag; a stale copy is served while it refreshes |
| Catalogue download failure | 15 min backoff, shared by app and CLI |
| Inspector details | 24 h; not stored if the README couldn't be fetched. Fresh details read the stored verdict; stale ones revalidate it |
| Release notes | on demand (one API call), stored in `details` by tag; shown while that tag is the latest |
| README | revalidated with its stored ETag; "no README" trusted for 7 days |
| Live search answer | 24 h; an empty answer 1 h |
| Refresh | skipped if the last one finished under 2 h ago, unless forced ([refresh.md](../features/refresh.md)) |
| Decoded `release.json` (API path) | in memory and `<caches>/github/release-json/<asset id>.json`; assets don't change |
| `release.json` by tag (github.com path) | `release_json` table (about 600 B each), no expiry: tags don't change. Fetched once per tag, not once per process |
| API checks per repo | 6 h for bulk and background checks, unless the latest tag changed |
| API release lists | in memory for the last 64 repos, revalidated with ETags |
| Downloaded zips | newest 2 per add-on (rollback) |
| Screenshots | `URLCache` 32 MB memory / 200 MB disk in `<caches>/screenshots/`, written and read by the loader itself, so headers don't decide; decoded images in an `NSCache` |

The refresh also re-checks repos whose catalogue entry changed after `checked_at`, and a slice older than 14 days.

## ETags and update checks

- `InstalledAddon.etag` is stored **only while the add-on is up to date**. A 304 then always means "still current", never "an update you haven't installed".
- Changing an add-on's channel clears its ETag.
- Unauthenticated 304s still cost API quota, which is why stable-channel update checks use the quota-free `releases/latest` redirect first ([github-endpoints.md](github-endpoints.md)).
- The core's URL session has no HTTP cache; ETags are handled explicitly.

## Clearing

- `AddonManager.clearCaches()` empties the `support`, `repo_meta`, `details` and `release_json` tables and deletes everything under Caches (downloads, `release.json` files), including rollback zips.
- `addonctl cache clear` empties only Caches; `cache clear --metadata` also empties the metadata tables except `rate_limit` ([cli/maintenance.md](../cli/maintenance.md#cache)).
- `addonctl cache info` shows the sizes.

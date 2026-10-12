# Caching

What is cached, for how long, how ETags and failures are handled, and the single-owner rule with `CachePolicy`.

## Rules

- **Cache everything, failures included**, with a TTL. A repo that 404s or has no Forever build is remembered too.
- **Use ETags** for anything that can change. Send `If-None-Match`; a 304 means the stored copy is current.
- **Never refetch what's stored and fresh.**
- **One owner per kind of remote data** decides freshness. Nobody else keeps a second cache.

## Single cache owner and `CachePolicy`

> **Landing with the core merge.** Why: [decision 0011](../decisions/0011-single-cache-owner.md).

| Data | Owner | Stored in |
|---|---|---|
| Forever support, latest tag | `GitHubSource.check` | SQLite metadata DB |
| Catalogue | `CatalogueSource` | SQLite metadata DB |
| Downloaded zips | `Downloader` | `<caches>/downloads/` |
| Screenshot bytes | `ScreenshotLoader` | its own `URLCache` |

Callers state intent; the owner decides whether to hit the network:

| `CachePolicy` | Meaning |
|---|---|
| `.preferStored` | Use what's stored; go to the network only if nothing is stored |
| `.revalidateIfStale` | Use stored data while fresh; revalidate once past its TTL |
| `.forceRevalidate` | Revalidate now (still sending the ETag), e.g. for an explicit user check |

Callers never pass `maxAge: 0`-style flags or `reuse: false`, and never call the endpoints around the owner.

## TTLs

| What | Where (this branch) | Lifetime |
|---|---|---|
| Parsed catalogue | `<caches>/catalogue.plist` (binary plist, with ETag) | 24 h; a stale copy is used if the network fails |
| Support statuses | `<caches>/forever-support.json`, keyed by ref + game version | 6 h; `.checking` and `.unknown` are never saved |
| Decoded `release.json` | in memory and `<caches>/github/release-json/<asset id>.json` | forever (assets don't change) |
| Inspected zips | `<caches>/downloads/github/<asset id>-<name>` | until evicted |
| Downloaded install zips | `<caches>/downloads/…` | newest 2 per add-on (for rollback) |
| Live GitHub search results | in memory, per query | 10 min |
| Inspector details | in memory, per add-on | the app session |
| Screenshots | `URLCache` 32 MB memory / 200 MB disk; decoded `NSCache` | HTTP cache rules |

After the core merge:

| What | Lifetime |
|---|---|
| GitHub fallback query results | 24 h; an empty result 1 h |
| Catalogue, support and tags | in SQLite; refreshed by the [2-hour refresh](overview.md) |

## ETags and update checks

- `InstalledAddon.etag` is stored **only while the add-on is up to date**. A 304 then always means "still current", never "an update you haven't installed".
- Without a caller ETag, `GitHubSource` still revalidates its own in-memory copy.
- Changing an add-on's channel clears its ETag.
- Unauthenticated 304s still cost API quota, which is why update checks move to the quota-free `releases/latest` redirect ([github-endpoints.md](github-endpoints.md)).

## Clearing

- `AddonManager.clearCaches()` and `addonctl cache clear` delete downloads, the catalogue and support checks. That also removes rollback zips, so the CLI asks first.
- `addonctl cache info` shows the sizes.

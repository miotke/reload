# GitHub endpoints

Every URL ForeverAddons requests, which ones cost API quota, the headers sent, rate-limit handling, and how errors are mapped.

Code: `Sources/AddonKit/GitHub/GitHubSource.swift`, `Search/GitHubSearchProvider.swift`, `Search/CatalogueSource.swift`, `AddonManager+Details.swift`, `Install/Downloader.swift`.

## Endpoints

| What | URL | API quota | Used by |
|---|---|---|---|
| Latest stable tag | `HEAD github.com/{owner}/{repo}/releases/latest`, redirect **not followed**; the tag is read from `Location: …/releases/tag/{tag}` | No | [support checks](../features/release-selection.md#support-checks), stable update checks and resolves |
| A tag's `release.json` or asset | `github.com/{owner}/{repo}/releases/download/{tag}/{file}` | No | support checks, [quota-free resolve](../features/release-selection.md#quota-free-resolve-stable-channel), installs |
| Latest release (notes) | `api.github.com/repos/{owner}/{repo}/releases/latest` | **Yes** | [release notes](../features/details-and-screenshots.md#release-notes), on demand |
| Release list | `api.github.com/repos/{owner}/{repo}/releases?per_page=10` | **Yes**, including a 304 when unauthenticated | the API resolve: prerelease channel, or when the latest release has no build for the flavor |
| `release.json`, zips (API path) | each asset's `browser_download_url` | No | API resolve, [Downloader](../features/installing.md#downloader) |
| Repo search | `api.github.com/search/repositories` | **Yes**, separate limit | [GitHub fallback](../features/search.md#github-fallback) |
| Catalogue | `raw.githubusercontent.com/layday/github-wow-addon-catalogue/main/addons.csv` | No | [catalogue import](../features/search.md#the-catalogue-cataloguesource) |
| README | `raw.githubusercontent.com/{owner}/{repo}/HEAD/<path>` (`HEAD` = the default branch) | No | [details](../features/details-and-screenshots.md#readme) |
| README fallback | `api.github.com/repos/{owner}/{repo}/readme` (only with a token) | Yes | details, when every path 404s |
| Rate limit | `api.github.com/rate_limit` | No | `addonctl doctor` |
| Screenshots | any host in the README | n/a | [ScreenshotLoader](../features/details-and-screenshots.md#screenshots) |

Avoid `releases/latest/download/release.json`: it takes 3 hops and about 350 ms. Why the github.com URLs: [decision 0010](../decisions/0010-quota-free-endpoints.md).

## Quota

| | Unauthenticated | With a token |
|---|---|---|
| REST API | 60 calls/h per IP | 5,000 calls/h |
| Search API | 10 calls/min | 30 calls/min |

- A `304 Not Modified` to an ETag request **still costs quota when unauthenticated**.
- `rateLimit()` reports the latest remaining count and reset time. It's stored in the database (`rate_limit`, resources `core` and `search`), so the app and CLI share it, and **no API request is sent while it says 0 calls are left** before the reset.
- `quotaIsComfortable()` is true above 30 calls left (or when nothing is known). Optional API calls, such as loading release notes automatically when a token is set, wait for it.
- The API support path keeps a 10-call reserve for installs and updates.

## Headers

| Header | When |
|---|---|
| `Accept: application/vnd.github+json` | API requests |
| `X-GitHub-Api-Version: 2022-11-28` | API requests |
| `User-Agent: ForeverAddons/<version> (+https://github.com/miotke/swift-addons)` | every core request |
| `Authorization: Bearer <token>` | API requests, only when a token is set. **Never** on github.com or asset requests |
| `If-None-Match: <etag>` | when an ETag is stored ([caching.md](caching.md)) |

The core uses one URL session: 20 s timeout, no waiting for connectivity, no HTTP cache. Background requests set `allowsConstrainedNetworkAccess = false`.

## Errors

**API (`api.github.com`):**

| Response | Result |
|---|---|
| 404 | `notFound` |
| 403 or 429 with no remaining quota, a `retry-after` header, or a "secondary rate limit" message | `rateLimited(resetAt:)`; with neither header it waits at least 60 s |
| 304 | `.notModified` (the stored copy is still current) |
| Any other non-2xx | `http(status:url:)` |

**github.com:**
- A 429 or 5xx is retried twice with jittered backoff (about 2 s, 4 s, or the `Retry-After`).
- A 429 that persists or asks to wait more than 30 s, or any 403, **pauses every github.com request** until it's over (at least 60 s for a 403).
- Other failures fall back to the API support path while quota is comfortable.

On `rateLimited` the app shows when checks can resume and suggests adding a token. Callers stop, rather than retry in a loop. Full error list: [errors.md](../architecture/errors.md).

## Concurrency

- At most 4 concurrent requests to github.com, with jitter ([refresh.md](../features/refresh.md#politeness)).
- Concurrent lookups for the same repo and flavor share one request.

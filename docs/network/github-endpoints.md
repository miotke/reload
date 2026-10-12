# GitHub endpoints

Every URL ForeverAddons requests, which ones cost API quota, the headers sent, and how errors are mapped.

Code: `Sources/AddonKit/Sources/GitHubSource.swift`, `Search/GitHubSearchProvider.swift`, `Search/CatalogueSource.swift`, `Install/Downloader.swift`.

## Endpoints

| What | URL | API quota | Used by |
|---|---|---|---|
| Release list | `api.github.com/repos/{owner}/{repo}/releases?per_page=10` | **Yes** | [release selection](../features/release-selection.md); the prerelease channel always |
| Latest release tag | `github.com/{owner}/{repo}/releases/latest` | No | support and update checks (landing with the core merge) |
| `release.json`, zips | each asset's `browser_download_url` (`github.com/{o}/{r}/releases/download/<tag>/<file>`) | No | selection, [Downloader](../features/installing.md#downloader) |
| Repo search | `api.github.com/search/repositories` | **Yes**, separate limit of 10/min unauthenticated | [GitHub fallback](../features/search.md#github-fallback) |
| Catalogue | `raw.githubusercontent.com/layday/github-wow-addon-catalogue/main/addons.csv` | No | catalogue layer |
| README, files | `raw.githubusercontent.com/…` | No | details (landing with the core merge) |
| Rate limit | `api.github.com/rate_limit` | No | `addonctl doctor` |
| Screenshots | any host in the README | n/a | [ScreenshotLoader](../features/details-and-screenshots.md#screenshots) |

### The `releases/latest` trick

`github.com/{o}/{r}/releases/latest` answers with a redirect to `…/releases/tag/<tag>`. The redirect is **not followed**: the `Location` header gives the tag, and `releases/download/<tag>/release.json` then gives the flavors. Both are quota-free. Why: [decision 0010](../decisions/0010-quota-free-endpoints.md).

Avoid `releases/latest/download/release.json`: it takes 3 hops and about 350 ms.

## Quota

| | Unauthenticated | With a token |
|---|---|---|
| REST API | 60 calls/h per IP | 5,000 calls/h |
| Search API | 10 calls/min | 30 calls/min |

- A `304 Not Modified` to an ETag request **still costs quota when unauthenticated**. That's why update checks with ETags cost 20 calls for 20 add-ons in the [baseline](budget.md).
- `rateLimit()` reports the latest `x-ratelimit-remaining` and reset time.
- Support checks stop when 10 or fewer calls are left, keeping a reserve for installs and updates.

## Headers

| Header | When |
|---|---|
| `Accept: application/vnd.github+json` | API requests |
| `X-GitHub-Api-Version: 2022-11-28` | API requests |
| `User-Agent: ForeverAddons/<version>` | every request |
| `Authorization: Bearer <token>` | API requests, only when a token is set. **Never** on asset downloads |
| `If-None-Match: <etag>` | when an ETag is stored ([caching.md](caching.md)) |

## Errors

| Response | Result |
|---|---|
| 404 | `notFound` |
| 403 or 429 with no remaining quota, or a `retry-after` header | `rateLimited(resetAt:)` |
| 304 | `.notModified` (the stored copy is still current) |
| Any other non-2xx | `http(status:url:)` |

On `rateLimited` the app shows when checks can resume and suggests adding a token. Callers stop, rather than retry in a loop. Full error list: [errors.md](../architecture/errors.md).

## Concurrency

- At most 4 concurrent requests to github.com, with jitter. Honour `retry-after`.
- Support checks during search (this branch) run 2 at a time.

# 0010: Quota-free GitHub endpoints and a small seed

Support and update checks use GitHub endpoints that cost no API quota; first launch seeds about 200 recent repos plus the installed ones, and a 2-hour refresh keeps them current.

- **Status:** Accepted, landing with the core merge
- **Date:** 2026-10-11

## Context

The API allows 60 calls an hour per IP without a token. In the baseline, a launch with 20 add-ons cost 20 API calls, because unauthenticated 304s with ETags still count. ⌘R with the quota gone produced 40 403s.

Some GitHub URLs aren't part of the API and cost no quota:

| URL | Gives |
|---|---|
| `github.com/{o}/{r}/releases/latest` | a redirect; the `Location` header holds the latest tag |
| `github.com/{o}/{r}/releases/download/<tag>/release.json` | the flavors of that release |
| `raw.githubusercontent.com/…` | the catalogue, READMEs |

`releases/latest/download/release.json` also works but takes 3 hops and about 350 ms.

## Decision

- **Latest tag:** request `releases/latest` and **don't follow the redirect**; read the tag from `Location`.
- **Flavors:** fetch `releases/download/<tag>/release.json`.
- **Files:** `raw.githubusercontent.com`.
- **First launch** seeds the top ~200 recently updated repos that have `release.json`, plus the installed ones: about **1,000 requests, ~25 s at concurrency 4, 0 API calls**.
- **Refresh every 2 hours** checks installed add-ons, repos whose catalogue `last_updated` changed, and a small rotating slice: about 5 + N requests.
- **Concurrency 4 with jitter**; honour `retry-after` and back off on 403/429.
- **The prerelease channel still needs the API** release list, since `releases/latest` skips prereleases.

## Alternatives considered

| Option | Why not |
|---|---|
| Seed all ~1,877 candidate repos | About 7,500 requests and ~3 minutes on first launch |
| Keep the API release list with ETags | 304s still cost quota without a token |
| Require a token | Contradicts "no keys needed" ([0002](0002-github-releases-no-keyed-apis.md)) |
| Follow the redirect | An extra hop for a page we don't need |
| Check everything every refresh | Wasteful; most repos don't change in 2 hours |

## Consequences

- Launch, refresh and stable-channel update checks cost 0 API calls.
- First launch takes about 25 s, shown behind the seeding sheet ([app/first-launch.md](../app/first-launch.md)).
- Repos outside the seed get support data when opened, searched via the fallback, or reached by the rotating slice.
- The app depends on GitHub's redirect behaviour, which isn't a documented API; if it changes, checks would have to move back to the API.

## See also

- [network/github-endpoints.md](../network/github-endpoints.md)
- [network/overview.md](../network/overview.md)
- [network/budget.md](../network/budget.md)

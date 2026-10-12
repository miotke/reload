# Network budget

How many requests each user action makes: the measured baseline before the core merge, and the design target the core merge implements.

Update these numbers after merges that change network behaviour (see `.claude/CLAUDE.md`).

## Baseline, before the core merge

Measured in the network audit at commit `561937a`. Unauthenticated, 20 installed add-ons.

| Action | API calls | Notes |
|---|---|---|
| Install 1 add-on | 1 | the release list |
| Launch / check for updates | 20 | one per installed add-on; 304s with ETags still cost quota unauthenticated |
| Typing "bigwigs" | 21 | support checks on each search |
| Category click | 15 | support checks on the top results |
| 3 searches over deleted repos | 45 | failures weren't cached |
| ⌘R with quota exhausted | 40 | all 403s |
| CLI `update` with nothing new | 20 | |
| Update All (5 add-ons) | 5 redundant | each add-on re-resolved after the check |
| App activation, store-watcher reload | 0 | |
| Browse (empty query) | 0 | |

The catalogue is one 186 KB download (609 KB uncompressed, 2,421 rows), cached 24 h with an ETag.

One launch, one search and one category click add up to 56 of the 60 calls allowed per hour.

## Target (the core merge's design, not yet re-measured)

| Action | Requests | API calls |
|---|---|---|
| Search, browse, sort, categories | 0 | 0 |
| Search with fewer than 3 local matches (3+ characters) | 1 | 1 search call (10/min limit), then cached 24 h |
| Opening details | 2–4 for that repo, only if stale | 0 |
| Refresh every 2 hours | about 5 + N (N = installed and changed repos) | 0 |
| First launch | about 1,000 (~25 s at concurrency 4) | 0 |
| Prerelease channel | release list | 1 per add-on |

Re-measure and replace this table with real numbers on the next network audit. How: [decision 0009](../decisions/0009-local-first-search.md), [decision 0010](../decisions/0010-quota-free-endpoints.md), [decision 0011](../decisions/0011-single-cache-owner.md).

## Side by side

| Action | Baseline API calls | Target API calls |
|---|---|---|
| Launch / check for updates | 20 | 0 (quota-free refresh) |
| Typing "bigwigs" | 21 | 0 |
| Category click | 15 | 0 |
| CLI `update`, nothing new | 20 | 0 on the stable channel |

## Useful facts

- REST API: 60 calls/h per IP unauthenticated, 5,000 with a token.
- Search API: 10 calls/min unauthenticated.
- `releases/latest/download/release.json` takes 3 hops and about 350 ms; use the `releases/latest` redirect plus `releases/download/<tag>/release.json` instead ([github-endpoints.md](github-endpoints.md)).
- Seeding all ~1,877 candidate repos on first launch was rejected: about 7,500 requests and ~3 minutes.

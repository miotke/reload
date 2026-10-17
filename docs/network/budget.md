# Network budget

How many requests each user action makes: the measured baseline before the core merge, the numbers measured at `05ba0ff`, and what changed after the fixes in [decision 0017](../decisions/0017-details-without-quota-release-json-by-tag.md).

Update these numbers after merges that change network behaviour (see `.claude/CLAUDE.md`).

## Measured: baseline and `05ba0ff`

From the network audits. Unauthenticated, 20 installed add-ons. Each cell is **core API / search API / quota-free** requests.

| Flow | Baseline (`561937a`) | Now (`05ba0ff`) |
|---|---|---|
| First launch / seed (0 installed) | n/a | 0/0/347 (1 catalogue + 200 HEAD + 146 `release.json`), ~6–18 s |
| Install 1 add-on | 1/0/2 | 0/0/3 |
| Launch within 2 h | 20/0/0 | 0/0/0 |
| Launch after 2 h | 20/0/0 | 0/0/40 |
| ⌘R | 20/0/0 | 0/0/21 |
| Type "bigwigs" | 21/0/11 | 0/0/0 |
| Category click | 15/0/5 | 0/0/0 |
| Too few local hits | 3/3/1 | 0/1/0, then cached |
| Open details (cold) | n/a | 1/0/4–5 |
| Update All (5) | 5/0/5 zips | 0/0/5 zips |
| CLI update, nothing new | 20/0/0 | 0/0/40 |
| ⌘R ×2 at quota 0 | 40 (403s) | 0/0/60 |
| Search ×3 over 404 repos | 45 | 0 |
| Offline, 5 searches | 5 failed fetches | 1 (15 min backoff) |
| 2nd installation's first refresh | n/a | 0/0/343 |

Since 0.1.4, a forced refresh with WoWInterface and Tukui on adds their two listings: ⌘R is 0/0/23 in `NetworkBudgetTests`. Refreshes within 24 h add nothing ([sources.md](../features/sources.md)).

The catalogue is one 186 KB download (609 KB uncompressed, 2,421 rows), cached 24 h with an ETag.

At the baseline, one launch, one search and one category click added up to 56 of the 60 calls allowed per hour.

## After these fixes

Rows the 0017 changes affect. **Measured** rows come from the offline request-count tests (`NetworkBudgetTests`, `DetailsTests`, `WebSupportTests`) over stubbed HTTP; **expected** rows follow from the same code paths but weren't counted end to end.

| Flow | Before (`05ba0ff`) | After | |
|---|---|---|---|
| Open details (cold) | 1/0/4–5, plus zips for repos without `release.json` | 0/0/3–4 (HEAD, the tag's `release.json`, README paths), never a zip | measured |
| Open details again, any process, within 24 h | 0/0/0 | 0/0/0 | measured |
| Release notes | part of every cold open | 1/0/0 on **Show Release Notes**, then stored by tag | measured |
| Launch after 2 h (relaunch) | 0/0/40 | 0/0/20: one HEAD per add-on, no `release.json`; +1 when the catalogue's 24 h is up | measured |
| ⌘R in a new process | 0/0/21 | 0/0/21, none of it `release.json` | measured |
| A new tag for an installed add-on | its `release.json` in every process | that `release.json` once; other processes reuse it | measured |
| 2nd installation's first refresh, within 1 h | 0/0/343 | 0/0/0 (tags shared, verdicts from stored `release.json`) | measured |
| 2nd installation's first refresh, later | 0/0/343 | up to 100 HEADs (smaller seed), `release.json` only for new tags | measured with 10 repos; 100 expected |
| CLI update, nothing new | 0/0/40 | 0/0/20 | expected |
| Opening Installed (0.1.9) | n/a | 0/0/0 within the hour; 0/0/20 (one HEAD each) once answers are older | measured (`openingInstalledChecksOnlyStaleAddons`) |
| ⌘R ×2 at quota 0 | 0/0/60 | 0/0/40, HEADs only | expected |
| ⌘R for add-ons only the API can decide | 1 core call each | 1 per repo every 6 h, or when its latest tag changes; one add-on's own update always asks | measured |
| A github.com failure in a background check | could spend an API call and overwrote the verdict | 0 API calls; verdict kept, retried after 15 min | measured |
| Live search with a stored answer | 500 ms wait first | answered at once, no "searching GitHub" state | measured |

### Visible-row checks ([decision 0019](../decisions/0019-available-games-and-visible-row-checks.md))

| Flow | Cost | |
|---|---|---|
| Scroll Browse, rows without a fresh answer | ≤ 0/0/20 per pause: one HEAD each, plus `release.json` only for tags not stored. 4 at a time | measured (`VisibleCheckTests`) |
| The same rows again within their lifetime | 0/0/0 | measured |
| Rows already in flight, Low Data Mode, github.com pausing | 0/0/0 | measured |
| A search for 20 repos outside the seed, scrolled once | 0/0/20–40, never an API call | expected |

How: [decision 0009](../decisions/0009-local-first-search.md), [0010](../decisions/0010-quota-free-endpoints.md), [0011](../decisions/0011-single-cache-owner.md), [0017](../decisions/0017-details-without-quota-release-json-by-tag.md), [0019](../decisions/0019-available-games-and-visible-row-checks.md).

## Quota status

`gitHubStatus()` (`AddonManager+Maintenance.swift`) reports what the settings screen shows, without a request:

| Field | From |
|---|---|
| `api` | `GitHubAPIClient`'s tracked `core` limit; the stored row on first use. Nil after a token change until GitHub answers |
| `search` | the stored `search` row |
| `apiLimit` | the last `x-ratelimit-limit`, else 60 or 5,000 by token |
| `hasToken` | whether a token is configured (environment or Keychain) |
| `webPausedUntil` | `GitHubWebClient`'s pause, only while it's in the future |

A window whose reset time has passed is reported full (`remaining` = limit, no reset). Rate-limit writes don't emit a `metadataChanges()` event, since `MetadataChange` has no kind for them; the app re-reads on appear.

## Useful facts

- REST API: 60 calls/h per IP unauthenticated, 5,000 with a token.
- Search API: 10 calls/min unauthenticated.
- `releases/latest/download/release.json` takes 3 hops and about 350 ms; use the `releases/latest` redirect plus `releases/download/<tag>/release.json` instead ([github-endpoints.md](github-endpoints.md)).
- Seeding all ~1,877 candidate repos on first launch was rejected: about 7,500 requests and ~3 minutes.
- A stored `release.json` is about 600 B; 200 seeded repos add about 120 KB to `metadata.sqlite`.

## Reload's own updates

Sparkle, in Release builds ([app/updates.md](../app/updates.md)): once a day, `github.com/miotke/reload/releases/latest/download/appcast.xml` (a quota-free redirect to the release-assets host), and the zip only when a newer version is installed. Never the API, and not counted in the add-on flows above.

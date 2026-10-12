# 0017: Details and release notes without API quota; release.json stored by tag

Opening an add-on spends no API quota and downloads no zips; release notes are a separate, on-demand call. Decoded `release.json` files are stored in SQLite by `repo@tag`, latest tags are shared between flavors, failures sit beside verdicts instead of replacing them, and bulk checks ask the API about a repo at most every 6 hours.

- **Status:** Accepted
- **Date:** 2026-10-11

## Context

The network audit at `05ba0ff` ([budget.md](../network/budget.md)) found:

- `details` called `github.resolve` for release notes: one core API call per cold open while quota was above 30, so 30 opens drained the unauthenticated quota to its floor. With zip downloads on, it downloaded a zip for repos without `release.json`, and fetched `release.json` a second time.
- Every new process re-downloaded `release.json` for every installed add-on: `updateState` asked for the build before comparing tags, and the by-tag cache was memory-only. A launch after 2 h cost 40 requests instead of 20.
- A second installation of another flavor repeated the whole 200-repo seed (~343 requests, ~18 s), though tags don't depend on the flavor.
- A transient failure overwrote a good verdict with `error`, and background checks could fall back to the API.
- A stored "no README" was ignored (8 × 404 every 24 h), and live search waited 500 ms before reading its own stored answer.
- Add-ons only the API can decide cost one call each on every ⌘R.

## Decision

1. **Details are quota-free.** `details` reads support and the latest tag from `GitHubSource.latestRelease` (`.revalidateIfStale` when the details are stale, the stored answer otherwise) and never resolves. `AddonDetails.latestChangelog` is filled only from stored notes for the current tag.
2. **Release notes on demand.** `AddonManager.releaseNotes(for:in:)` → `(version, publishedAt, markdown)?`: stored notes for the tag, else one call to `releases/latest` (none if this process holds the release list), never a zip. Stored in `details` by tag. The inspector shows **Show Release Notes**; with a token and comfortable quota, `details` loads them itself.
3. **`release.json` by tag in SQLite** (`release_json`, ~600 B each, no expiry). Update checks compare tags first and fetch the build only for a new tag.
4. **Shared tags.** With `.revalidateIfStale`, `latestRelease` reuses a `repo_meta.latest_tag` under 1 h old, whatever flavor stored it; the verdict then comes from the stored `release.json`. A later installation's first seed checks 100 repos instead of 200.
5. **Failures beside verdicts.** `support` gains `error_at` and `retry_after`; `status` becomes nullable. A failure keeps the last good status and tag (`LatestRelease.failed` marks it) and is retried after 15 minutes. With no verdict, the answer is `.unknown` and no status is stored. Background checks never fall back to the API.
6. **API throttle.** `repo_meta.api_checked_at` / `api_checked_tag` record each API call. Bulk and background checks (⌘R, the 2-hour refresh, `outdated`, Update All) ask again only after 6 h, or when the free latest tag changed, reusing the last stored update state meanwhile. An explicit single-add-on action always asks.
7. The README's stored "none" is trusted for 7 days; live search reads `search_cache` before the settle delay.

Schema: migration 3 ([data-storage.md](../architecture/data-storage.md#migrations)). The single-owner rule of [decision 0011](0011-single-cache-owner.md) holds: `GitHubSource` owns tags, verdicts, `release.json` and API timing.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep notes in `details`, only while quota is comfortable | Still drains a shared 60/h quota by browsing |
| `release.json` files on disk by tag | A second store to clear and size; SQLite already holds the verdicts |
| Strict 6 h throttle, ignoring tag changes | ⌘R would hide a real new release for up to 6 h when github.com already saw it, free |
| Separate failure table | Another join for every verdict read; two columns are enough |

## Consequences

- A relaunch after 2 h costs one HEAD per installed add-on; a second flavor's seed within the hour costs nothing ([budget.md](../network/budget.md#after-these-fixes)).
- Release notes for browsed add-ons need a click without a token.
- Within the 6 h window, a prerelease that doesn't move the stable tag shows up late on bulk checks; updating that one add-on asks at once.
- `refresh_state.updates_json` is written by bulk checks too, not only by refreshes.
- Verdict rows can exist with a NULL status; readers filter on `status IS NOT NULL`.

## See also

- [network/caching.md](../network/caching.md), [features/details-and-screenshots.md](../features/details-and-screenshots.md#release-notes), [features/refresh.md](../features/refresh.md)

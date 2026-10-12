# 0011: One owner for support state, chosen by cache policy

`GitHubSource` is the only code that decides Forever support and latest tags; callers state intent with a `CachePolicy` (`.preferStored`, `.revalidateIfStale`, `.forceRevalidate`) and never bypass it.

- **Status:** Accepted
- **Date:** 2026-10-11

## Context

Support verdicts and latest tags were cached in two places: an in-memory cache in `GitHubSource` and the SQLite `support` table. Callers decided freshness between them, by checking `isFresh`, passing flags, or calling the tag and `release.json` lookups directly. In the user's review of in-progress code, calls like `check(reuse: false)` and `latestTag(maxAge: 0)` showed up.

That duplicated the "latest tag → `release.json`" logic and made it easy to force a request every time, or to trust an answer that was too old. The baseline had the same smell elsewhere: Update All on 5 add-ons re-resolved each one after the check ([budget.md](../network/budget.md)).

## Decision

1. **Single owner.** `GitHubSource.latestRelease(for:flavor:policy:)` is the only code that decides support. It reads and writes the stored verdicts and latest tags itself (`SupportCache` over the `support` and `repo_meta` tables). There is no other support cache. The raw lookups (`fetchLatestTag`, `webReleaseJSON`) are private to `GitHubSource`; callers never judge freshness. A test checks that no other file reaches them.
2. **Cache policy instead of flags:**

   | `CachePolicy` | Network | Store |
   |---|---|---|
   | `.preferStored` | never | read only; `.unknown` if nothing is stored |
   | `.revalidateIfStale` | only when the stored answer is past its lifetime | writes what it learns |
   | `.forceRevalidate` | always asks for the latest tag; still reuses the stored verdict when the tag is unchanged | writes what it learns |

3. **One shared primitive.** `latestRelease` answers "what's the latest stable release, and does it support the flavor" (`LatestRelease { tag, status, build }`). `check` returns its verdict; update checks use the same answer (and its `release.json` build) to decide "up to date" or build a quota-free `ResolvedRelease`; installs use it through `quotaFreeResolve`.
4. **Concurrent callers share one request:** a second lookup for the same repo and flavor waits for the first.
5. **Lifetimes** (for `.revalidateIfStale`): verdicts 1 h, negative answers (no releases) 24 h, failed checks 15 min ([caching.md](../network/caching.md#lifetimes)).

### Who uses which policy

| Caller | Policy |
|---|---|
| Search and Browse | none: they read stored verdicts only |
| Opening details | `.revalidateIfStale` |
| Background refresh (every 2 h): update and support phases | `.revalidateIfStale`; the support phase reuses what the update phase just stored |
| Explicit check (⌘R, `checkForUpdates`, `addonctl outdated`/`update`), forced refresh, install, `update` | `.forceRevalidate` |

## Alternatives considered

| Option | Why not |
|---|---|
| Freshness flags per call (`reuse:`, `maxAge:`) | What the review found; each caller decides differently |
| Callers read the `support` table directly | The owner can't enforce lifetimes or negative caching |
| Keep the in-memory cache next to SQLite | Two sources of truth that can disagree |

## Consequences

- Freshness rules live in one place (`SupportCache` lifetimes plus the policy).
- A forced check of an unchanged repo costs one `HEAD`.
- The refresh may still pre-filter its targets as an optimisation, but `check` remains the authority.
- Writes happen per check rather than in caller-side batches.
- The same rule ("one owner per kind of remote data") is in `.claude/CLAUDE.md` and applies to the catalogue, details and downloads too.

## See also

- [features/release-selection.md](../features/release-selection.md#support-checks)
- [features/refresh.md](../features/refresh.md)
- [network/caching.md](../network/caching.md)

> **Update 2026-10-12:** the owner moved from `GitHubSource` to `LatestReleaseStore` (`Sources/AddonKit/GitHub/LatestReleaseStore.swift`) in the core refactor. The decision is unchanged.

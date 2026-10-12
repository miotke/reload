# 0011: One cache owner per kind of data, with CachePolicy

Each kind of remote data has one owner that decides freshness; callers state intent with a `CachePolicy` (`.preferStored`, `.revalidateIfStale`, `.forceRevalidate`) and never bypass the owner.

- **Status:** Accepted, landing with the core merge
- **Date:** 2026-10-11

## Context

While reviewing in-progress core code, the user found callers that reached around the cache:

- `check(reuse: false)` to skip stored support data
- `latestTag(maxAge: 0)` to force a fresh tag

Each call site was making its own freshness decision. That leads to:
- the same repo fetched more than once in one action (compare the baseline's "Update All (5): 5 redundant re-resolves" in [budget.md](../network/budget.md))
- second caches that disagree with the first
- quota spent where stored data was fine

## Decision

- **`GitHubSource.check` owns Forever support and latest-tag data**, stored in SQLite ([0008](0008-sqlite-metadata-database.md)). Nothing else stores or fetches them.
- Callers pass a **`CachePolicy`**:

| Policy | Intent |
|---|---|
| `.preferStored` | use what's stored; fetch only if nothing is |
| `.revalidateIfStale` | use stored data while fresh, revalidate past its TTL |
| `.forceRevalidate` | revalidate now (still with ETags), for explicit user checks |

- Callers **never** bypass the owner, keep a second cache, or pass `maxAge: 0` / `reuse: false`-style flags.
- The same rule applies to other data: one owner each (catalogue, downloads, screenshots).

## Alternatives considered

| Option | Why not |
|---|---|
| Freshness flags per call (`reuse:`, `maxAge:`) | What was found in review; each caller decides differently |
| Callers read SQLite directly | Owners can't enforce TTLs or negative caching |
| A global "offline mode" switch | Too coarse; doesn't express per-action intent |

## Consequences

- Freshness rules live in one place per kind of data and are easy to change.
- One user action fetches a repo at most once.
- Reviews can reject any new `maxAge`-style parameter on sight.
- APIs that had freshness flags change signature during the core merge.

## See also

- [network/caching.md](../network/caching.md)
- `.claude/CLAUDE.md`, "Network rules"

# 0009: Local-first search

Search, browse, sorting and categories read only the local database; GitHub is asked automatically only when a 3+ character query has fewer than 3 local matches.

- **Status:** Accepted, landing with the core merge
- **Date:** 2026-10-11

## Context

Before the core merge, each search ran Forever support checks on the top ~15 results against the GitHub API. The network audit (commit `561937a`, unauthenticated, 20 installed add-ons) measured:

| Action | API calls |
|---|---|
| Typing "bigwigs" | 21 |
| Category click | 15 |
| 3 searches over deleted repos | 45 |

With 60 calls an hour, a launch plus one search and one category click nearly used up the quota, leaving nothing for installs and updates.

## Decision

- **Search, browse, sort and categories read only the local SQLite database** ([0008](0008-sqlite-metadata-database.md)). No per-search support checks; badges come from stored data, kept fresh by refresh ([0010](0010-quota-free-endpoints.md)).
- **Automatic GitHub fallback:** one search request when there are **fewer than 3 local matches** and the query is **3+ characters**.
- Fallback results are **written into the local catalogue**, so they're found locally next time.
- Query results are cached **24 hours**; an empty result **1 hour**.
- The search API limit (10 requests a minute unauthenticated) is respected.
- **Search GitHub for More Results** and `addonctl search --github` still ask GitHub on demand.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep per-search support checks, with a smaller limit | Still spends quota on every keystroke burst |
| Never fall back automatically | Add-ons missing from the catalogue would look like they don't exist |
| Keep the old trigger (fewer than 5 catalogue matches, any length) | Fires on short or partial queries while the user is still typing |

## Consequences

- Typing, sorting and browsing cost 0 network requests.
- Search speed depends only on the local index (p50 0.29 ms per keystroke).
- Badges can be up to one refresh interval old; opening details revalidates that one repo.
- Failed and empty lookups are cached, so repeated searches for deleted repos cost nothing.

## See also

- [features/search.md](../features/search.md)
- [network/budget.md](../network/budget.md)

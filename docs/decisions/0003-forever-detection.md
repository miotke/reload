# 0003: Forever detection with release.json first

A release supports Forever if its `release.json` says so; without one, the zip's TOC files decide. All Forever constants live in one `FlavorRules` table.

- **Status:** Accepted; partly superseded by [0016](0016-one-flavor-per-game.md) (the per-game `FlavorRules` table and TOC choice). The `release.json`-first order still holds.
- **Date:** 2026-10-11

## Context

The manager has to decide *whether* a release supports Forever and *which* asset to download. The game client picks the right TOC itself, so installing is just extracting the zip.

Signals available:
- The BigWigs packager's `release.json` lists each zip's flavors, e.g. `{"flavor":"forever","interface":16001}`. It's a release asset, so downloading it costs no API quota.
- Inside a zip, a Forever TOC (`BigWigs_Camelot.toc`, `-Forever.toc`) or an `## Interface:` value in the `16xxx` range.
- The catalogue's `flavors` column, which under-reports Forever.

Forever's values (beta 1.60.1) may change at launch.

## Decision

1. **`release.json` first.** Pick the first full (non-`nolib`) build whose metadata includes `forever`, and the asset named in `filename`.
2. **Zip TOC inspection as the fallback** (`ZipInspector`), when a release has no `release.json`. At most 3 zip inspections per resolve.
3. Walk releases newest first; if one has no Forever build, try the next older one.
4. **One table, `FlavorRules`,** holds every constant:
   - interface 16000–19999 (`16xxx`)
   - TOC suffixes `Camelot` and `Forever`, after `_` or `-`
   - `_Mainline` counts when its interface is in range
   - `release.json` flavor `forever`
   - known folder `_classic_beta_` → `wow_classic_beta`
5. Search support checks never download zips; without `release.json` they report `.needsDownload`.

## Alternatives considered

| Option | Why not |
|---|---|
| Trust the catalogue's `flavors` column | Under-reports Forever |
| Always inspect the zip | A download per check; slow and heavy for search |
| Match on the TOC suffix only | Add-ons that ship one `_Mainline` TOC with a `16xxx` interface would be missed |
| Constants spread across the code | Forever's launch would mean hunting through files |

## Consequences

- Most releases resolve with one quota-free `release.json` download.
- Authors who dropped Forever support leave users on the last working version.
- When Forever launches with new values, only `FlavorRules` changes.
- `ResolvedRelease.reasoning` records each step, printed by `reload resolve`.

## See also

- [features/release-selection.md](../features/release-selection.md)
- [architecture/flavors.md](../architecture/flavors.md)

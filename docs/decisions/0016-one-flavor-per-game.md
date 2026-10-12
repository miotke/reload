# 0016: One flavor per game, rules as data

Each game version is its own `Flavor` (`mainline, forever, vanilla, tbc, wrath, titan, cata, mists`) with disjoint interface ranges and its own `FlavorRules` entry; shared TOC suffixes count only when their interface is in range, and no API has a default flavor.

- **Status:** Accepted
- **Date:** 2026-10-11

## Context

Before this change `Flavor` had `forever`, `mainline` and one lumped `classic`. That caused real problems:

- **Wrong builds.** `classic` covered every classic game, so a Mists Classic install could pick a Vanilla build: any `_Classic` TOC or `classic` `release.json` entry matched.
- **Overlapping ranges.** `classic`'s interface range overlapped Forever's `16xxx`. Only the order of checks kept Forever installs detected as Forever.
- **Stored as text.** The metadata database keys `support` and `details` rows by flavor name, so `classic` rows can't be told apart after a split.
- **Hidden defaults.** Several APIs defaulted to `.forever`, so a caller that forgot the installation's flavor silently got Forever answers.

## Decision

- **One flavor per game:** `mainline` (Retail), `forever`, `vanilla` (Classic Era), `tbc` (TBC Anniversary), `wrath`, `titan`, `cata`, `mists`. The full table is in [flavors.md](../architecture/flavors.md#flavors).
- **Disjoint ranges.** No two flavors' interface ranges overlap, so `Flavor.from(interface:)` has one answer whatever the check order. Mainline keeps the original pre-classic ranges (10000–11299, 20000–20499, …) and everything from 60000 on.
- **Rules as data.** Each flavor's `FlavorRules` lists its interface ranges, own TOC suffixes, shared TOC suffixes in client order, `release.json` names and known folders.
- **TOC choice:** an own suffix decides on its own; otherwise the first shared TOC in order, then the base TOC. **A shared suffix counts only when its interface is in range** (`_Mainline` for Forever, `_Classic` for the classics).
- **Detection by version.** `.build.info`'s version decides; the folder and product code are fallbacks ([finding-wow.md](../features/finding-wow.md)).
- **No default flavor arguments** anywhere (`SearchQuery.init`, `SupportCache`, `SearchCoordinator.browse`). `SearchQuery.foreverOnly` became `compatibleOnly`.
- **Migration 2** deletes `support` and `details` rows with `flavor = 'classic'`. Saved installations with `"flavor":"classic"` are re-derived when loaded.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep `classic` with sub-flavors | The build differs per game; every check would still need the sub-flavor, so it's a flavor in all but name |
| Detect from the folder name | `_classic_` has held different games over time (it's Mists today); folders only seed the product code |
| Keep `.forever` defaults | Silent wrong answers for non-Forever installations |
| Migrate `classic` rows to a guessed flavor | They can't be told apart, and they're only a cache |

## Consequences

- Each classic install gets builds for its own game.
- **Adding a game version is a new `Flavor.rules` entry** (plus a display name), not new code paths.
- Titan has no suffix of its own and treats `_Wrath` / `_WOTLKC` TOCs as shared, so they count only with a Titan interface.
- Callers must pass the installation's flavor explicitly; the compiler catches omissions.
- The app and CLI show `displayName`s ("Mists Classic only", "no Retail build"). Product framing (the app name, `_classic_beta_` hints) stays Forever-specific on purpose.
- Old `classic` verdicts are re-checked on the next refresh.

## See also

- [architecture/flavors.md](../architecture/flavors.md)
- [features/release-selection.md](../features/release-selection.md#zipinspector-does-a-zip-support-the-flavor)
- [decision 0003](0003-forever-detection.md), partly superseded

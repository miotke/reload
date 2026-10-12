# 0019: Show available games instead of a support verdict; check visible rows

Browse, the inspector and the CLI show which games an add-on ships builds for (Retail, Forever, Classic) instead of one "Forever: yes / no / unknown" verdict; a Retail build can be installed on Forever only by explicit choice; and the rows on screen are checked quota-free, so search results outside the seed don't stay unknown.

- **Status:** Accepted
- **Date:** 2026-10-12

## Context

- **AutoPotion showed "? unknown".** Its latest `release.json` (v3.17.1) lists `mists`, `mainline`, `wrath`, `cata`, `classic`, `bcc` and `forever` builds. It was never checked: it isn't in the 200-repo seed, and search makes no network calls ([decision 0009](0009-local-first-search.md)). The catalogue's `flavors` column for it omits `forever`, which is why that column isn't trusted.
- **"Not Forever" isn't "won't work on Forever".** Forever runs on the modern (Retail) UI:
  - It loads `_Camelot.toc` / `_Forever.toc` and, per the Warcraft Wiki, falls back to the `_Mainline` family TOC ([TOC format](https://warcraft.wiki.gg/wiki/TOC_format)).
  - Retail-only add-ons often work, but are listed as **out of date** until the player ticks *Load out of date AddOns* ([wow4ever.quest](https://wow4ever.quest/en/addons), [wowforeverguides.com](https://wowforeverguides.com/addons)). Removed or restricted APIs still break some; the combat log is restricted.
  - Classic-only add-ons generally don't load ([forever-addon-kit](https://github.com/Thunderz96/forever-addon-kit)).
  - Developers disagree on whether `_Mainline` wins over a missing `_Camelot` ([AdventureGuideClassic#80](https://github.com/fooxytv/AdventureGuideClassic/pull/80)). There's no official Blizzard statement.
- The old "Forever only" toggle hid every `.unsupported` verdict. In a fresh seed (171 repos checked, measured with the app in a temp data folder) that was 136 rows, 127 of them with a Retail build; only 9 are classic-only.

## Decision

1. **Game families.** `GameFamily { retail, forever, classic }`, `Flavor.family`, a letter and a display name ([flavors.md](../architecture/flavors.md#game-families)).
2. **Store every flavor a release ships.** `latestRelease` / `check`, the single owner ([decision 0011](0011-single-cache-owner.md)), return `availableFlavors: Set<Flavor>?` beside the verdict and store it per repo in `repo_meta` (migration 5, backfilled from the `release_json` rows of [decision 0017](0017-details-without-quota-release-json-by-tag.md)). No `release.json`: nil, unless an installed or adopted zip's TOCs fill it in. `SupportStatus` stays for install logic.
3. **Surface it.** `SearchResult`, `AddonDetails` and Browse rows carry `availableFlavors` and `families`. `compatibleOnly` becomes `hideIncompatible`, per family: Forever hides classic-only, Retail hides results without Retail, the classics hide results without Classic; unknown stays ([search.md](../features/search.md#hide-incompatible)).
4. **Retail build on Forever, opted into.** `allowFamilyFallback: true` installs the `mainline` build when there's no `forever` one; `installedFlavorBuild` keeps update checks on it until a Forever build appears, which is then the update. Without the flag it's `noCompatibleRelease` ([release-selection.md](../features/release-selection.md#retail-build-on-forever)).
5. **Visible-row checks.** `checkVisible(_:in:)` runs `latestRelease(.revalidateIfStale, background: true)` for rows on screen without a fresh answer: github.com `HEAD releases/latest` plus the tag's `release.json`, never the API; 20 refs per call, 4 at a time, in-flight refs dropped; skipped while github.com pauses us and on Low Data Mode ([refresh.md](../features/refresh.md#visible-row-checks)).
6. **App and CLI.** R / F / C bubbles (`GameBubbles`) replace the badge everywhere, with a legend, per-family toggle labels and **Install Retail Build…**; the CLI gets a GAMES column, JSON fields and `install --retail-build` ([app/layout.md](../app/layout.md#games), [cli/output.md](../cli/output.md#terminal-output)).

## Alternatives considered

| Option | Why not |
|---|---|
| Keep the verdict and add "may work" | Still one flavor's answer; hides which games are covered and can't sort by it |
| Trust the catalogue's `flavors` column | Under-reports Forever (AutoPotion) |
| Install the Retail build automatically when there's no Forever one | Updates could silently switch builds, and some Retail add-ons break on Forever |
| Check every search result as it arrives | Up to 200 repos per query; scrolling past rows shouldn't cost requests for rows never seen |
| Visible checks through the API | Shares a 60/h quota with installs and updates |
| `onScrollPhaseChange` / scroll geometry for visible rows | `Table` is AppKit-hosted and these give offsets, not rows; cell `onAppear` / `onDisappear` names the rows on screen directly |

## Consequences

- AutoPotion and BetterBags show **R F C** and "Has a Forever build" once checked; a Retail-only add-on shows **R** with the out-of-date caveat, and Hide Classic-only keeps it.
- With the toggle on, Forever users see far more rows than before (only classic-only ones are hidden). Rows whose own game isn't confirmed are dimmed.
- Scrolling Browse costs at most 20 quota-free HEADs per pause, plus a `release.json` per new tag; answers within their lifetime cost nothing ([budget.md](../network/budget.md#visible-row-checks-decision-0019)).
- A Retail build on Forever can break; the app says so before installing and shows **Build: Retail build** afterwards.
- `repo_meta` gains three columns; available flavors are per repo, so a second installation's flavor reads them for free.

## See also

- [architecture/data-storage.md](../architecture/data-storage.md#migrations), [network/caching.md](../network/caching.md)

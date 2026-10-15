# Flavors and TOC parsing

The `Flavor` enum and its `FlavorRules` table (one entry per game version, each with its own interface ranges, TOC suffixes, `release.json` names and folders), plus the pure parsers for TOC, `release.json` and `.build.info` files.

Code: `Sources/AddonKit/Model/Flavor.swift`, `Sources/AddonKit/Parsing/`. Why one flavor per game: [decision 0016](../decisions/0016-one-flavor-per-game.md).

## Flavors

`Flavor` is `mainline, forever, vanilla, tbc, wrath, titan, cata, mists`. Every game-version-specific constant lives in `Flavor.rules`. Adding a game version means adding an entry; when Forever launches with a final folder and product code, only its entry changes.

| Flavor | Display name | Interface / game versions | Own TOC suffixes | Shared TOC suffixes | `release.json` | Folder → product |
|---|---|---|---|---|---|---|
| `mainline` | Retail | 10000–11299, 20000–20499, 30000–30399, 40000–40399, 50000–50499, 60000–999999 | Mainline | — | mainline, retail | `_retail_`→wow, `_ptr_`→wowt, `_beta_`→wow_beta |
| `forever` | Forever | 16000–19999 | Camelot, Forever | Mainline | forever, camelot | `_classic_beta_`→wow_classic_beta |
| `vanilla` | Classic Era | 11300–15999 | Vanilla | Classic | classic, vanilla | `_classic_era_`→wow_classic_era |
| `tbc` | TBC Anniversary | 20500–29999 | TBC, BCC | Classic | bcc, tbc | `_anniversary_`→wow_anniversary |
| `wrath` | Wrath Classic | 30400–37999 | Wrath, WOTLKC | Classic | wrath | — |
| `titan` | Titan | 38000–39999 | — | Wrath, WOTLKC, Classic | titan | — |
| `cata` | Cata Classic | 40400–49999 | Cata | Classic | cata | — |
| `mists` | Mists Classic | 50500–59999 | Mists | Classic | mists | `_classic_`→wow_classic |

- **Ranges are disjoint**, so `Flavor.from(interface:)` and `Flavor.from(gameVersion:)` have exactly one answer. Interfaces and game versions encode the same way (`major·10000 + minor·100 + patch`: `11508` is 1.15.8, `16001` is 1.60.1), so the ranges bound both.
- Mainline's ranges are the original releases before each classic re-release, then everything from 6.0 on.
- Suffixes are matched after `_` or `-`, case-insensitively.
- **Shared suffixes count only when the TOC's interface is in the flavor's range**: `_Mainline` counts for Forever only with a `16xxx` interface, `_Classic` for any classic game with an interface in its range. Titan has no suffix of its own, so it treats `_Wrath`/`_WOTLKC` TOCs as shared.
- `displayName` is what the app and CLI show ("No Forever build yet", "no Retail build").

### Helpers

| Helper | Does |
|---|---|
| `FlavorRules.contains(interface:)` | interface in any of the flavor's ranges |
| `Flavor.from(gameVersion:)`, `from(interface:)` | the flavor whose ranges contain it |
| `Flavor.from(productCode:)`, `from(subfolder:)` | lookups in `knownSubfolders` (folder case-insensitive) |
| `TocFileName.sharedRank(for:)` | position of a TOC's suffix in the flavor's shared list; lower is tried first |

`FlavorRules.interfaceRange` became `interfaceRanges`, and `InstallationLocator.flavor(forSubfolder:)` / `flavor(forProduct:)` moved to `Flavor.from(subfolder:)` / `from(productCode:)`.

There are no `flavor` default arguments anywhere (`SearchQuery.init`, `SupportCache`, `SearchCoordinator.browse`): callers always pass the installation's flavor.

## Game families

Players care less about the eight flavors than about three games. `GameFamily` (`Model/GameFamily.swift`) groups them, and the app's R / F / C bubbles and the CLI's GAMES column show which ones an add-on ships builds for ([decision 0019](../decisions/0019-available-games-and-visible-row-checks.md)).

| `GameFamily` | Letter | Flavors |
|---|---|---|
| `retail` | R | `mainline` |
| `forever` | F | `forever` |
| `classic` | C | `vanilla`, `tbc`, `wrath`, `titan`, `cata`, `mists` |

- `Flavor.family`, and `GameFamily.letter` / `displayName` / `flavors`.
- **Every flavor a release ships** (`availableFlavors: Set<Flavor>`, nil = not known) comes from its `release.json` (`ReleaseJSON.availableFlavors`: every full build's metadata, mapped by `Flavor.from(releaseJSONName:)`). Without one, from the TOCs of a zip that was installed or adopted (`ZipInspector.availableFlavors`): a flavor's own suffix names it (`_Mainline` → Retail, `_Camelot` / `_Forever` → Forever, `_Mists` → Mists), and a TOC's interfaces add the flavors that may load it (`_Mainline` with `16001` → Forever too). A base TOC counts by its interfaces; `_Classic` with no classic interface counts as Classic Era.
- **Forever runs on the modern UI.** It loads `_Camelot` / `_Forever` TOCs and falls back to the `_Mainline` family TOC ([TOC format](https://warcraft.wiki.gg/wiki/TOC_format)). Retail-only add-ons often work there but are listed as out of date until *Load out of date AddOns* is ticked; removed APIs and the restricted combat log still break some. Classic-only add-ons generally don't load. So `Flavor.forever.fallbackFlavor` is `.mainline` ([release-selection.md](../features/release-selection.md#retail-build-on-forever)).
- `Flavor.hidesAsIncompatible(families:support:)` is the search filter's rule per family ([search.md](../features/search.md#hide-incompatible)); `GameAvailability.sentence` is the one-line summary the inspector and `reload info` show ("Has a Forever build", "Retail build only: may work on Forever; it will show as out of date", "Classic only: won't load on Forever", "Not checked yet").

## How an add-on ships per-game builds

Most add-ons are built by the [BigWigs packager](https://github.com/BigWigsMods/packager). It uploads **one zip covering every game version**, plus a `release.json`:

```json
{"releases":[{"name":"BigWigs","version":"v426.4","filename":"BigWigs-v426.4.zip","nolib":false,
  "metadata":[{"flavor":"mainline","interface":120100},{"flavor":"forever","interface":16001}]}]}
```

Inside the zip there are often several TOCs per add-on (`BigWigs.toc`, `BigWigs_Mainline.toc`, `BigWigs_Camelot.toc`). **The game client picks the right TOC itself**, so installing means extracting the zip as-is. The manager only decides *whether* a release supports the installation's flavor and *which* asset to download ([release-selection.md](../features/release-selection.md)).

## Parsers

All parsers are pure functions, and their tests use fixture files.

| Parser | Reads |
|---|---|
| `Toc` | `## Key: Value` headers |
| `TocFileName` | `BigWigs_Camelot.toc` → add-on `BigWigs`, suffix `Camelot` (`_` or `-`) |
| `ReleaseJSON` | the packager format above |
| `BuildInfo` | Blizzard's pipe-separated `.build.info` |

### Toc

- Handles a byte-order mark, CRLF line endings and case-insensitive keys.
- `## Interface:` may be a comma-separated list (`120100, 16001`), parsed into `[Int]`.
- Reads `Title`, `Version`, `Notes`, `Author`, dependencies, and `X-Website`, `X-Github`, `X-Curse-Project-ID`, `X-Wago-ID` and `X-WoWI-ID` (used to suggest a repo when adopting).
- Strips WoW colour and texture codes from titles for display. `displayTitle` also drops a version written into the title, and `displayVersion` is `## Version` (unless it's an unexpanded `@project-version@`) or else that version: `Questie|cFF00FF00 v12.0.4|r` → "Questie", `v12.0.4`.
- Which of a folder's TOCs the client loads: `ZipInspector.readTocs(addonFolder:flavor:)`, the same rule as the zip check ([release-selection.md](../features/release-selection.md#zipinspector-does-a-zip-support-the-flavor)).

### ReleaseJSON

- `name` and `version` are optional because older packager versions omit them.
- `release(for:)` picks the first full (non-`nolib`) build whose metadata names one of the flavor's `release.json` values (e.g. `forever` or `camelot` for Forever).

### BuildInfo

- BPSV format: a header like `Name!TYPE:len|…`, then pipe-separated rows. Lines starting with `#` are comments.
- Only the `Product` and `Version` columns matter here.

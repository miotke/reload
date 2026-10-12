# Flavors and TOC parsing

The `FlavorRules` table that holds every Forever-specific constant, and the pure parsers for TOC, `release.json` and `.build.info` files.

Code: `Sources/AddonKit/Model/Flavor.swift`, `Sources/AddonKit/Parsing/`. Why one table: [decision 0003](../decisions/0003-forever-detection.md).

## FlavorRules

All game-version-specific constants live in one table. When Forever launches with a final folder name and product code, that table is the only thing that changes.

| | Forever |
|---|---|
| Interface range | 16000–19999 (currently `16001`) |
| Game versions | 1.60.0–1.99.99 |
| TOC suffixes | `Camelot`, `Forever` (after `_` or `-`) |
| Shared TOC suffixes | `Mainline`, which counts only if its interface is in range |
| `release.json` flavor | `forever` |
| Known folders | `_classic_beta_` → product code `wow_classic_beta` |

`mainline` and `classic` exist in the `Flavor` enum so the model never assumes a single game version, but only Forever is managed today.

`Flavor.from(gameVersion:)` maps a build version such as `1.60.1.70338` to a flavor using the game-version range. [finding-wow.md](../features/finding-wow.md) uses it.

## How an add-on ships Forever support

Most add-ons are built by the [BigWigs packager](https://github.com/BigWigsMods/packager). It uploads **one zip covering every game version**, plus a `release.json`:

```json
{"releases":[{"name":"BigWigs","version":"v426.4","filename":"BigWigs-v426.4.zip","nolib":false,
  "metadata":[{"flavor":"mainline","interface":120100},{"flavor":"forever","interface":16001}]}]}
```

Inside the zip there are often several TOCs per add-on (`BigWigs.toc`, `BigWigs_Mainline.toc`, `BigWigs_Camelot.toc`). **The game client picks the right TOC itself**, so installing means extracting the zip as-is. The manager only decides *whether* a release supports Forever and *which* asset to download ([release-selection.md](../features/release-selection.md)).

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
- Reads `Title`, `Version`, `Notes`, `Author`, dependencies and `X-Website` (used to suggest a repo when adopting).
- Strips WoW colour and texture codes from titles for display.

### ReleaseJSON

- `name` and `version` are optional because older packager versions omit them.
- `release(for:)` picks the first full (non-`nolib`) build for a flavor.

### BuildInfo

- BPSV format: a header like `Name!TYPE:len|…`, then pipe-separated rows. Lines starting with `#` are comments.
- Only the `Product` and `Version` columns matter here.

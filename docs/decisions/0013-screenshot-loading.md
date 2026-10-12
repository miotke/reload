# 0013: Screenshot loading

Screenshots are downloaded once to a disk cache, decoded as thumbnails at display size with ImageIO, and decoded at full resolution only in the viewer; at most 6 per add-on, 5 MB each, with badges and SVGs skipped.

- **Status:** Accepted
- **Date:** 2026-10-11

## Context

The inspector shows images from an add-on's README. READMEs mix real screenshots with status badges and logos, and screenshots are often large PNGs. Decoding them at full size for a 320 px strip wastes memory and main-thread time, and arrow-keying through a table would start a download for every row.

## Decision

- **Filter:** drop badge hosts (shields.io, badgen and similar), CI badges (`…/badge.svg`) and all SVGs. Keep at most **6** images per add-on.
- **Download once:** `ScreenshotLoader` has its own `URLSession` with a dedicated `URLCache` (32 MB memory, 200 MB disk). Refuse images over **5 MB**.
- **Thumbnails:** decode with ImageIO at display size (320 px on the long side), off the main actor, lazily as the strip scrolls.
- **Full resolution only in the viewer** (up to 2000 px), when the user clicks a thumbnail.
- **Cache decoded images** in an `NSCache` keyed by size and URL.
- **Cancel** loads when the selection changes (`.task(id:)`).

## Alternatives considered

| Option | Why not |
|---|---|
| `AsyncImage` | No control over decode size or which cache is used; can't draw SVG anyway |
| The shared `URLSession` cache | No separate size limits for image bytes |
| No size cap | A few huge GIFs could fill the cache |
| **Host thumbnails** (e.g. Imgur's size suffixes) | Considered and **deferred**: saves bandwidth for some hosts, but needs per-host rules |

## Consequences

- Decoded thumbnails are small, so the `NSCache` holds many of them ([measurements](../performance/measurements.md) for app memory).
- Scrolling the strip and switching rows stay smooth.
- Some real screenshots that are SVGs or over 5 MB don't show.
- Images on slow hosts still download in full before the thumbnail appears; host thumbnails could fix that later.

## See also

- [features/details-and-screenshots.md](../features/details-and-screenshots.md#screenshots)
- [performance/guidelines.md](../performance/guidelines.md#images)
- [decision 0012](0012-inspector-and-tables.md) for where the inspector sits

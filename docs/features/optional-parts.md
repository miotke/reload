# Optional parts

Extra add-ons that a managed add-on can use and that its own GitHub repo publishes as a separate release stream. Spoken's voice packs are the example, but nothing here is specific to Spoken.

Contract: `AddonManaging.optionalParts(of:in:policy:)`, `OptionalPart` (`Sources/AddonKit/Model/OptionalParts.swift`) and `AddonRef.tagPrefix`.

## The shape it handles

One repo, several add-ons, told apart by tag prefix:

| Tag | Zip | What it is |
|---|---|---|
| `spoken/v3.8.4` | `Spoken-3.8.4.zip` | the add-on and its modules |
| `places-audio/v2.1.0` | `SpokenPlacesAudio-2.1.0.zip` | a voice pack, 435 MB |
| `manager/v0.1.12` | `.dmg`, `.AppImage` … | a desktop app, not an add-on |

The add-on's TOC names the parts it can use: `Spoken_Places.toc` has `## OptionalDeps: SpokenPlacesAudio`.

## The rule

1. Read the loaded TOCs of the managed add-on's folders (the same rule as [dependencies](dependencies.md#detection)) and take their `OptionalDeps`.
2. List the repo's releases (one cached, ETag'd request; none with `.preferStored`).
3. A folder becomes a part when exactly one tag prefix's latest stable release has a zip whose name starts with that folder name followed by `-` or `_`. The part's ref is the repo plus that `tagPrefix`.
4. State: `available`, `unmanaged` (the folder is in `AddOns/`; adopt it) or `installed`.

A ref with a `tagPrefix` only ever resolves, checks and updates within `<prefix>/…` tags. Parts are never installed without the user choosing them: they can be over 1 GB.

# Optional parts in the app

How the inspector shows a managed add-on's optional parts: extra add-ons its own GitHub repo publishes as separate tag streams, such as Spoken's voice packs. Which folders are parts, their state, ref, version and size are the core's ([optional-parts.md](../features/optional-parts.md)); the app only maps them to rows and never installs one on its own.

Code: `App/Reload/Models/InspectorModel.swift` (loading), `Models/OptionalPartsList.swift`, `Support/OptionalPartSupport.swift` (`OptionalPartRow`), `Views/OptionalPartsSection.swift`, `Views/AddonInspectorView.swift` (placement and the load task). Tests: `App/ReloadTests/OptionalPartTests.swift`.

## The section

Shown after Requires, for managed add-ons only, and only when the core reports at least one part.

```
Optional Parts
Extra add-ons from Spoken's repository that it can use. Reload only installs them when you ask.
SpokenPlacesAudio                          [Install (435 MB)]
v2.1.0 · Used by Spoken_Places
SpokenQuestAudio                           ▬▬▬▭▭ Downloading…
v1.4.0 · Used by Spoken_Quests
SpokenNPCAudio                             [Manage…]
v1.0.0 · 210 MB · Used by Spoken_NPCs
SpokenEmotes                               ✓ Installed
v0.3.0 · 12 MB
```

| `OptionalPart.state` | Action |
|---|---|
| `available` | **Install (435 MB)**: `UpdateQueue.install(part.ref, …)`, with the usual download progress and errors on the part's own row state |
| `unmanaged` | **Manage…**: a confirmation saying the release is downloaded over the folder, then `UpdateQueue.adopt(folder:as: part.ref)`, which shows download progress (the core's `adopt(folder:as:in:progress:)`) and errors on the folder's row |
| `installed` | a quiet green check and "Installed" |

- The name is the folder. The version drops the tag prefix (`places-audio/v2.1.0` reads `v2.1.0`). Sizes use `ByteCountFormatter` (file style); the Install button carries the size, so the detail line leaves it out there.
- A failed listing keeps the rows already shown and adds "Couldn't check optional parts: …". With no rows the section stays hidden, so an offline add-on without parts shows nothing.

## Loading and freshness

- `AddonDetailView` runs `InspectorModel.loadOptionalParts(for:)` keyed on the installed ref, debounced 250 ms in the inspector like the details.
- It asks `optionalParts(of:in:policy:)` with `.preferStored` first (local), then `.revalidateIfStale`: opening an add-on is an allowed network moment, and the core decides whether to ask GitHub.
- The same task then follows `metadataChanges()` for the add-on's repo (`ref.repo`) and re-reads with `.preferStored`, until the selection moves on.
- Install store changes (`InstalledModel.didChangeInstallState`) and the CLI's metadata writes (`AppModel.reloadMetadataIfChanged`) call `reloadOptionalParts()`, which re-reads every shown list with `.preferStored`, coalesced into one pass.
- Lists are kept for the 20 most recently shown add-ons, like details. Each is its own `@Observable`, so a reload re-renders only its section, and each part's progress lives in its `RowState`.

## Refs with a tag prefix

An installed part's ref is the repo plus `tagPrefix` (`owner/repo#places-audio`).

- Row IDs are `AddonRef.description` (`github:owner/repo#places-audio`); `AddonRef(rowID:)` reads the prefix back.
- The Installed table's subtitle is `repositoryText`: "owner/repo · places-audio".
- Links (inspector, context menus) use `webURL`, which is the repo's page.
- Details go to the core with the part's own ref; whether its README and stats come from the repo is the core's call.

## Tests

`OptionalPartTests` covers the row wording for each state, the version and size, `AddonRef(rowID:)` with a prefix, and the model over `FixtureManager` (stored first, then revalidated; reload after a change; a failed revalidate keeping the rows).

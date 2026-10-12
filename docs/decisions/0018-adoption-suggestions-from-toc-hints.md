# 0018: Adoption suggestions from TOC hints and the catalogue

Unmanaged folders are described by the TOC the game loads for the installation's flavor, and their repository is suggested locally from hints in all of their TOCs matched against the catalogue, with a reason. Folders one release ships are grouped once a download has shown what the release contains.

- **Status:** Accepted
- **Date:** 2026-10-12

## Context

On the user's Forever beta install, `AddOns/Questie/` showed as "Questie — game client not supported", version "—", and the Adopt sheet suggested nothing:

- `reconcile` read `F/F.toc` first. Questie's base `Questie.toc` is its fallback for unsupported clients (`## Interface: 00000`). Forever loads `Questie_Camelot.toc` (16001, "Questie v12.0.4").
- The only suggestion source was `X-Website` on that one TOC. Questie lists no website, but every flavor TOC has `X-Curse-Project-ID: 334372` and `X-Wago-ID: qv634BKb`, and the local catalogue row `Questie/Questie` has exactly those IDs.
- `QuestieDB/` sat as an unrelated row, though one Questie release may ship both folders.
- Unmanaged folders could only be adopted, never removed from the app or CLI.

## Decision

1. **Read the TOC the client loads.** `ZipInspector.readTocs(addonFolder:flavor:)` shares `loadedToc` with the zip check: the flavor's own suffix, then the first shared suffix, then the base TOC. The entry records `tocFile`, `supportsFlavor` ("not loaded by Forever" when false) and shows `displayTitle` / `displayVersion` (colour codes and a version in the title split apart).
2. **Suggest from all TOCs, locally.** `AdoptionIndex` (built from the stored catalogue, cached per catalogue generation) matches in order: `X-Website`/`X-Github` on github.com, `X-Curse-Project-ID` → `curse_id`, `X-Wago-ID` → `wago_id`, `X-WoWI-ID` → `wowi_id`, exact catalogue name on folder or title, repository name. Each `AdoptionCandidate` has `ref`, `name`, `reason` and `confidence` (high for links and IDs, medium for names, low for repo names). Several candidates at the best confidence are ambiguous: the user picks. `AddonManager.adoptionCandidates(folder:in:)` exposes it; `addons(in:)` fills `suggestedRef` with the best one.
3. **Group by what the release ships.** `release_folders` (migration 4) stores the top-level folders of a repo's zip whenever one is downloaded (any install, or the Adopt preview). Unmanaged folders that a suggested release ships become one entry. Without that row, only folders whose unambiguous best suggestion is the same repo group.
4. **Preview before adopting.** `adoptionPreview(for:folders:in:)` resolves normally (quota-free with `release.json`), downloads the zip into the cache the install reuses, and lists the folders it replaces, adds or conflicts with. A missing build for the flavor is reported before anything changes.
5. **Remove unmanaged folders.** `removeUnmanaged(folders:from:)` checks every name first (no `Blizzard_*`, nothing managed, only folders directly in `AddOns/`) and then trashes them.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep reading the base TOC | Shows the fallback's "not supported" title for Questie and similar add-ons |
| Look hints up on CurseForge or Wago | Keyed APIs ([decision 0002](0002-github-releases-no-keyed-apis.md)); the catalogue already maps their IDs |
| Live GitHub search for every unmanaged folder | Spends the 10/min search quota on every reload; it stays an explicit "Search GitHub…" |
| Group by folder-name prefix (`Questie*`) | Wrong for add-ons that are separate projects, like QuestieDB may be |
| Inspect the latest release of every suggestion to group | One download per unmanaged folder per reload; recording what downloads show costs nothing extra |

## Consequences

- Questie on Forever reads as "Questie", `v12.0.4`, "Matched CurseForge project 334372". QuestieDB stays a separate row until a downloaded Questie release is seen to ship it.
- Suggestions are only as good as the local catalogue: before the first catalogue download, only TOC GitHub links suggest anything.
- Grouping can be stale after a release adds or drops a folder, until the next download of that repo.
- The Adopt preview downloads the zip before the user confirms; the install then reuses it, so confirming costs nothing more.
- `AddonStatus.unmanaged` carries an `UnmanagedFolder` instead of a tuple; app and CLI pattern matches changed with it.

## See also

- [features/installing.md](../features/installing.md#adopting-unmanaged-folders), [architecture/data-storage.md](../architecture/data-storage.md#reconcile)

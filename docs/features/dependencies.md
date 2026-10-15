# Dependencies

Add-ons that need other add-ons: how Reload finds missing ones, offers to install them, and warns before removing one that others need.

Code: `Sources/AddonKit/AddonManager+Dependencies.swift` (detection, candidates, dependents), `Sources/AddonKit/Selection/DependencyMatcher.swift` (ranking, pure), `Sources/AddonKit/Model/Dependencies.swift` (the model types).

## Why it matters

A TOC can name folders that must be in `AddOns/` for the game to load it:

```
## Dependencies: BigWigs
```

`## RequiredDeps:` and `## Dep:` mean the same. Without the folder, the game lists the add-on as "Missing dependency" and doesn't load it. LittleWigs is the usual example: it needs BigWigs, which is a separate download (`BigWigsMods/BigWigs`). `## OptionalDeps:` only changes load order, so it never counts.

## The contract

All of it is local: the TOCs on disk and the metadata database. No network.

| Method | Returns |
|---|---|
| `missingDependencies(in:)` | every `MissingDependency` of the installation's managed add-ons, by folder name |
| `missingDependencies(of:in:)` | the same for one managed add-on, e.g. right after installing it |
| `dependents(of:in:)` | managed add-ons that would stop loading if `ref` were uninstalled |

`MissingDependency` has the `folder` (as the TOC spells it), `requiredBy` (managed add-ons, by name), `candidates` (best first, at most 5) and `suggested` (the one to install without a choice, or nil). `DependencyPolicy` (`ask`, `install`, `warn`) is what a front end does with a suggestion after an install; the app keeps it as a setting, the CLI asks.

## Detection

`AddonManager.scanDependencies` runs off the actor:

1. List `AddOns/` once. Every folder there counts as present, managed or not, compared without case.
2. For each managed add-on, read the TOC the game loads for the installation's flavor in each of its folders, by the same rule as unmanaged folders and zips (`ZipInspector.readTocs`, [data-storage.md](../architecture/data-storage.md#reconcile)): the flavor's own suffix, then the first shared suffix, then the base TOC. A folder with none of those isn't loaded, so it requires nothing.
3. Take its `requiredDependencies`, dropping:
   - `Blizzard_*` folders, which ship with the game;
   - the add-on's own folders: one of those missing is a missing folder (`list --missing`), not a dependency.
4. A required folder that isn't present is missing. Add-ons that need the same folder share one entry.

Example: LittleWigs' `LittleWigs.toc` (Retail) and `LittleWigs_Camelot.toc` (Forever) can differ; on Forever only the `_Camelot` one is read.

Cost: 100 managed add-ons with two folders and two TOCs each take about 35 ms, candidates included (`DependencyTests`).

## Candidates

For each missing folder, from **sources that are on** (`enabledSources()`, [sources.md](sources.md#turning-sources-on-and-off)) only:

| Tier | Where from | Reason shown | Strength |
|---|---|---|---|
| 1 | `release_folders`: the folders a release's zip shipped when it was last downloaded (any install or Adopt preview records it) | "Its download shipped the BigWigs folder" | strong |
| 2 | Hosted listings: WoWInterface's `UIDir` and Tukui's `directories`, stored in `catalogue.folders_json` | "WoWInterface lists the BigWigs folder" | strong |
| 3 | Catalogue names, through `AdoptionIndex` with no TOC hints (GitHub only, like adoption) | "Named BigWigs in the catalogue", "Its repository is named BigWigs" | weak |

- Folder names match without case. Each add-on appears once, with its strongest reason.
- Within tier 1, an add-on named like the folder comes first. Within tier 2, the same, then the most recently updated. Tier 3 keeps `AdoptionIndex`'s order (newest first).
- Names come from the installed record, else the catalogue row, else the repo name.

**`suggested`** is set only when one answer is certain:
- the only candidate in tier 1, if tier 1 has any;
- else the only candidate in tier 2, if tier 2 has any;
- else, with no strong match at all, the only candidate, when its name or repo name is the folder.

Two downloads that both shipped the folder, two listings, or two repos named BigWigs suggest nothing: the user picks. A seen download outranks a listing, so once BigWigs from GitHub has been downloaded, it's suggested over the WoWInterface copy.

Listings stored before migration 7 have no folders. The migration marks them stale, so the next refresh fills them ([data-storage.md](../architecture/data-storage.md#migrations)).

## Dependents

`dependents(of: ref)` reads the other managed add-ons' loaded TOCs the same way and returns those that require a folder `ref` owns, unless another folder in `AddOns/` provides it. Front ends use it to warn before uninstalling: "LittleWigs needs BigWigs and will stop loading".

## Not done

- Required folders of unmanaged folders aren't checked.
- Dependencies of dependencies are found only after the first one is installed.

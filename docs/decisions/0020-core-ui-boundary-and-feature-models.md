# 0020 — Core/UI boundary and feature models

**Status:** Accepted · **Date:** 2026-10-12

## Context

UI changes took agents 20–30 minutes each. Most "UI" requests cut through every layer, and the app had grown its own business logic:
- a 749-line `InstallationModel` held Browse, Installed, search, refresh, updates, details and row state
- the app cast to `AddonManager` to reach the metadata database and install store
- it decided install actions, compatibility filtering and fallback builds itself

`GitHubSource` (984 lines) mixed the API client, github.com client, caching and README fetching. Agents couldn't see the UI either, so visual bugs reached the user.

## Decision

1. **Boundary:**
   - The app talks to the core only through `AddonManaging` and public model types.
   - Only `AppEnvironment.swift` names `AddonManager`.
   - Observation goes through `metadataChanges()`, `metadataVersion()`, `storeDirectory` and `storedAvailability(for:in:)`.
   - `ArchitectureTests` enforces this.
2. **Decisions live in the core.** `InstallAction`, `UpdateOffer`, `BrowseFilter`, `AdoptionPreview.canAdopt` and `AddonRef(parsing:)`. The app only displays their results, and a second scan forbids re-implementing them.
3. **Feature models in the app:** `BrowseModel`, `InstalledModel`, `InspectorModel`, `UpdateQueue` and `LiveMetadata`, under a thin `InstallationModel`.
4. **The core's GitHub code:** `LatestReleaseStore` (single cache owner), `GitHubAPIClient`, `GitHubWebClient`, `ReadmeFetcher`, plus `GitHubSource` for API resolve and zip inspection. `AddonManager` is split into feature files.
5. **Snapshots:** `SnapshotTests` render key views to `build/snapshots/*.png` in light and dark mode from test-only fixtures. Agents view them after UI changes.
6. **Workflow:** features are split into a core task and a UI task with the contract defined first ([`.claude/CLAUDE.md`](../../.claude/CLAUDE.md)). The "Where things live" tables plus `scripts/check-docs.swift` keep the file map current.

## Alternatives considered

- **Keep one model and add MARK sections.** Rejected: agents still had to read and edit one hot file, and parallel UI work kept colliding.
- **`ImageRenderer` for snapshots.** Tried; it leaves scroll views blank and draws some buttons as placeholders. Offscreen `NSHostingView` is used instead.
- **Mock managers in the app for previews.** Rejected: the user wants real data only in the app. Fixtures live in the test target.

## Consequences

- UI and core tasks can run in parallel without touching each other's files.
- Each side's tests pass without the other changing.
- More, smaller files. The "Where things live" tables and the docs check keep them findable.
- Prominent buttons render grey in snapshots, as in an inactive window.

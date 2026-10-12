# Core library (AddonKit)

The `AddonKit` library, its `AddonManager` façade, how the components are layered, and where the code lives.

`AddonKit` does all the real work. The app and `addonctl` are thin front ends over it, and both go through one type: `AddonManager`. Why it's built this way: [decision 0001](../decisions/0001-swift-package-core.md).

```mermaid
flowchart TB
    App[ForeverAddons.app] --> AM
    CLI[addonctl] --> AM
    AM[AddonManager<br/>actor]
    AM --> Loc[InstallationLocator]
    AM --> GH[GitHubSource]
    AM --> DL[Downloader]
    AM --> Inst[Installer]
    AM --> Store[InstallStore]
    AM --> Search[SearchCoordinator]
    GH --> Sel[ReleaseSelector]
    GH --> Zip[ZipInspector]
    Inst --> Ext[ZipExtractor]
    Search --> Cat[CatalogueSource]
    Search --> GHS[GitHubSearchProvider]
    Search --> SC[SupportCache]
    Search -. support checks .-> GH
```

| Component | Doc |
|---|---|
| `GitHubSource`, `ReleaseSelector`, `ZipInspector` | [release-selection.md](../features/release-selection.md) |
| `Downloader`, `Installer`, `ZipExtractor` | [installing.md](../features/installing.md) |
| `InstallStore`, `AppDirectories`, metadata DB | [data-storage.md](data-storage.md) |
| `InstallationLocator` | [finding-wow.md](../features/finding-wow.md) |
| `SearchCoordinator` and providers | [search.md](../features/search.md) |
| `FlavorRules` and parsers | [flavors.md](flavors.md) |
| `AddonError` | [errors.md](errors.md) |

## Layering

- **All logic lives in `AddonKit`.** Anything the app can do, `addonctl` can do.
- **Pure code is separate from I/O.** TOC and `release.json` parsing, flavor detection and release selection are plain functions on value types, tested with fixture files.
- **I/O sits behind protocols** (`HTTPClient`, `DownloadTransport`, `SupportChecking`), so tests never touch the network.
- **Shared state lives in actors.** See [concurrency.md](concurrency.md).

## Source layout

```
Sources/AddonKit/
├── AddonManager.swift       the façade (this doc)
├── AddonManaging.swift      the façade's protocol
├── Model/                   Flavor + FlavorRules, Installation, AddonRef, InstalledAddon,
│                            ResolvedRelease, search models, AddonError
├── Parsing/                 Toc, TocFileName, ReleaseJSON, BuildInfo (pure, no I/O)
├── Sources/                 Source/HTTPClient protocols, GitHubSource, GitHub API models
├── Selection/               ReleaseSelector, ZipInspector
├── Install/                 Downloader, ZipExtractor, Installer, InstallationLocator
├── Store/                   InstallStore, AppDirectories
├── Search/                  catalogue, index, providers, SupportCache, SearchCoordinator
└── Support/                 KeychainStore
```

## AddonManager

`AddonManager` is an actor that implements `AddonManaging`. Create one with no arguments for real use. Every dependency can be injected for tests: directories, `HTTPClient`, download transport, locator, installer, Keychain and environment.

| Area | Methods |
|---|---|
| Installations | `installations()`, `detectInstallations()`, `addInstallation(at:)`, `removeInstallation(_:)` |
| Add-ons | `addons(in:)` (managed + unmanaged, reconciled with disk), `installedAddons(in:)`, `lookup(_:in:)` |
| Search | `search(_:in:)` → `AsyncStream<[SearchResult]>`, `browse(in:)` |
| Install | `resolve(_:for:channel:)`, `install(_:into:channel:force:progress:)`, `adopt(folder:as:in:)` |
| Updates | `checkForUpdates(in:)`, `update(_:in:)` → `AsyncStream<OperationEvent>` |
| Changes | `uninstall`, `rollback`, `setPinned`, `setChannel` |
| Details and refresh | `details(for:in:)`, `refresh(in:force:)` → `AsyncStream<RefreshProgress>`, `lastRefresh(in:)` (placeholders on this branch; real versions land with the core merge) |
| Misc | `tokenDidChange()`, `rateLimit()`, `clearCaches()` |

### Behaviour worth knowing

- **Detection runs once.** `installations()` returns what's stored. Only the first call in a process with nothing stored runs Spotlight detection. After that, detection only runs when you call `detectInstallations()`.
- **Updates are detected by release, not version string.** An add-on is out of date when the chosen release has a different GitHub release ID *and* a later publish date (`InstalledAddon.isUpdate`). Version schemes are too inconsistent to compare (`v426.4`, `12.1.12`, `r1234-alpha`).
- **ETags are stored only while up to date.** That way a `304 Not Modified` always means "still current", never "an update you haven't installed".
- **Installs take the store lock.** See [installing.md](../features/installing.md).
- **Rollback.** Each install records the release it replaced in `previousRelease`. `rollback` reinstalls that release from the download cache, which keeps the last 2 zips per add-on, and **pins** the add-on so the next update doesn't undo it.
- **Updating:**
  - `update([])` updates every add-on. Pinned and up-to-date add-ons come back as `.skipped`.
  - Up to 4 add-ons are updated at once.
  - One failure doesn't stop the others.
- **`lookup` order:** a GitHub ref or URL first, then an installed add-on's name, repo or folder, then an exact catalogue name. More than one result means the input was ambiguous.
- **GitHub token:**
  - It comes from `ADDONS_GITHUB_TOKEN`, then `GITHUB_TOKEN`, then the Keychain (service `com.andrewmiotke.ForeverAddons`, account `github-token`).
  - `KeychainStore` lives in AddonKit so the app and the CLI share it.
  - Call `tokenDidChange()` after changing the Keychain item.

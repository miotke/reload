# WoW Forever Add-on Manager — Design & Architecture

A native macOS add-on manager for World of Warcraft, written in Swift, built first for **WoW Forever**.

Status: draft, written 2026-10-11 before any code exists.

---

## 1. Goals

- **Native Mac app.** SwiftUI app with a small, testable Swift core underneath it.
- **Forever first.** Every decision is checked against how Forever is packaged (interface `16xxx`, `_Camelot`/`-Forever` TOC suffixes). Other game versions should be easy to add later, but they aren't a v1 goal.
- **Find add-ons, not just manage them.** Search covers installed add-ons, a catalogue of GitHub-hosted add-ons and live GitHub, and shows whether each result supports Forever. See §7.
- **No gatekept APIs.** v1 uses only sources that need no developer key. Users may paste their *own* GitHub token to raise rate limits. The app never ships a secret.
- **Safe on disk.** The app never leaves `Interface/AddOns` half-written, never deletes a folder it didn't install without asking, and never writes outside `Interface/AddOns`.

### Non-goals (v1)

- CurseForge and Wago. Both need keys; see §11.
- Building add-ons from source, or installing from tags, zipballs or tarballs.
- Managing WeakAuras or other SavedVariables data.
- Windows or Linux support.

---

## 2. Background: how add-ons get published

Most popular add-ons are built by the [BigWigs packager](https://github.com/BigWigsMods/packager). The packager uploads **one zip that covers every game version** to CurseForge, Wago, WoWInterface and (if enabled) **GitHub Releases**. It also uploads a `release.json` describing that zip:

```json
{"releases":[{"name":"BigWigs","version":"v426.4","filename":"BigWigs-v426.4.zip","nolib":false,
  "metadata":[{"flavor":"mainline","interface":120100},{"flavor":"forever","interface":16001}]}]}
```

Inside the zip there are often several TOC files per add-on, such as `BigWigs.toc`, `BigWigs_Mainline.toc` and `BigWigs_Camelot.toc`. **The game client picks the right TOC itself**, so installing means extracting the zip as-is. The manager's job is to decide *whether* a release supports Forever and *which* asset to download.

### Forever facts (beta 1.60.1, subject to change at launch)

| Thing | Value |
|---|---|
| Install folder (beta) | `World of Warcraft/_classic_beta_/Interface/AddOns/` |
| `## Interface:` | `16xxx` (currently `16001`); game versions 1.60.0–1.99.x |
| TOC suffixes | `_Camelot`, `-Camelot`, `_Forever`, `-Forever`. `_Mainline` also applies if its interface list contains a `16xxx` value. |
| `release.json` flavor | `forever` |
| Build version source | `World of Warcraft/.build.info` (pipe-separated; `Product` and `Version` columns) |

None of these values may be hard-coded in more than one place. See §6.1.

---

## 3. Sources

| Source | Key needed | v1? | Notes |
|---|---|---|---|
| **GitHub Releases** | No (optional user token) | ✅ primary | Where most big add-ons publish (BigWigs, DBM, WeakAuras, Details, Plater, BugSack, …). |
| **GitHub catalogue** | No | ✅ for search | `raw.githubusercontent.com/layday/github-wow-addon-catalogue/main/addons.csv`, about 2.4k repos. Raw file, so no API quota. Its `flavors` column under-reports Forever and must not be trusted. |
| WoWInterface | No | v2 | `api.mmoui.com/v3/game/WOW/filelist.json` and `filedetails/{id}.json` |
| Tukui | No | v2 | `api.tukui.org/v1/addons` (ElvUI, Tukui) |
| CurseForge | Yes (Overwolf grants keys at its discretion) | ✗ | See §11 |
| Wago Addons | Yes (Bearer token, given to users through Wago's Patreon) | ✗ | See §11 |

---

## 4. Architecture overview

```
┌──────────────────────────────────────────────────────────────┐
│ ForeverAddons.app (Xcode, SwiftUI)                           │
│   Views  ←→  @Observable @MainActor view models              │
└───────────────────────────┬──────────────────────────────────┘
                            │ async calls
┌───────────────────────────▼──────────────────────────────────┐
│ AddonKit (Swift package library)                             │
│                                                              │
│  AddonManager (actor) — the façade that the app & CLI use    │
│    ├── InstallationLocator   find WoW, detect flavor         │
│    ├── Source protocol       GitHubSource, CatalogueSource,  │
│    │                         (later) WoWInterfaceSource …    │
│    ├── ReleaseSelector       pure: release.json / TOC rules  │
│    ├── Downloader            URLSession + cache dir          │
│    ├── Installer             staging, atomic swap, rollback  │
│    └── InstallStore (actor)  JSON per installation           │
│                                                              │
│  Models & parsers (pure, no I/O): Flavor, Toc, ReleaseJSON   │
└───────────────────────────▲──────────────────────────────────┘
                            │
┌───────────────────────────┴──────────────────────────────────┐
│ addonctl (Swift package executable) — package-manager CLI    │
└──────────────────────────────────────────────────────────────┘
```

Rules:

- **All logic lives in `AddonKit`.** The app and the CLI are thin and equal: two front ends over one core and one store (§9). Anything the UI can do, `addonctl` can do.
- **Pure code is separated from I/O.** TOC parsing, `release.json` parsing, flavor detection and release selection are plain functions on value types. They get exhaustive unit tests using fixture files.
- **Latest platform and language.** The minimum is macOS 27, built with Swift tools 6.4 in Swift 6 language mode with strict concurrency.
  - The package turns on `NonisolatedNonsendingByDefault` and `InferIsolatedConformances`. The app target also makes code run on the main actor by default.
  - Shared mutable state lives in actors (`AddonManager`, `InstallStore`). Small shared state uses `Mutex` (from the Synchronization module), not locks or `@unchecked Sendable`.

### Repository layout

```
addons/
├── DESIGN.md
├── Package.swift                 # AddonKit + addonctl + tests
├── Sources/
│   ├── AddonKit/
│   │   ├── Model/                # Flavor, Installation, InstalledAddon, AddonRef …
│   │   ├── Parsing/              # Toc.swift, ReleaseJSON.swift, BuildInfo.swift
│   │   ├── Sources/              # Source.swift, GitHubSource.swift, CatalogueSource.swift
│   │   ├── Selection/            # ReleaseSelector.swift
│   │   ├── Install/              # Installer.swift, ZipExtractor.swift, InstallationLocator.swift
│   │   ├── Store/                # InstallStore.swift
│   │   └── AddonManager.swift
│   └── addonctl/
│       └── main.swift
├── Tests/
│   └── AddonKitTests/
│       └── Fixtures/             # sample TOCs, release.json, GitHub API JSON, tiny zips
└── App/
    └── ForeverAddons.xcodeproj   # SwiftUI app; depends on the local package
```

### Third-party dependencies

- **[ZIPFoundation](https://github.com/weichsel/ZIPFoundation)** for reading and extracting zips. It's the only dependency.
- Everything else comes from Foundation: `URLSession`, `JSONDecoder`, `FileManager` and Security (Keychain).

---

## 5. Data model

```swift
enum Flavor: String, Codable, Sendable, CaseIterable {
    case forever            // v1
    case mainline, classic  // later; kept so the model doesn't assume one flavor
}

struct Installation: Codable, Sendable, Identifiable {
    var id: String              // stable hash of the resolved path
    var root: URL               // …/World of Warcraft/_classic_beta_
    var flavor: Flavor
    var productCode: String?    // e.g. "wow_classic_beta", from .build.info
    var gameVersion: String?    // e.g. "1.60.1.70338"
    var addonsDirectory: URL { root.appending(path: "Interface/AddOns") }
}

enum SourceID: String, Codable, Sendable { case github, wowinterface, tukui }

struct AddonRef: Codable, Hashable, Sendable {
    var source: SourceID
    var identifier: String      // "BigWigsMods/BigWigs" for GitHub
}

enum Channel: String, Codable, Sendable { case stable, prerelease }

struct InstalledAddon: Codable, Sendable, Identifiable {
    var id: AddonRef
    var name: String
    var folders: [String]       // top-level folders this package owns in AddOns/
    var version: String         // tag name, for display only
    var releaseID: Int64        // GitHub release id, used for update checks
    var assetName: String
    var publishedAt: Date
    var installedAt: Date
    var channel: Channel
    var pinned: Bool            // never auto-update
    var etag: String?           // last ETag from the releases endpoint
}

struct ResolvedRelease: Sendable {
    var ref: AddonRef
    var name: String
    var version: String
    var releaseID: Int64
    var publishedAt: Date
    var downloadURL: URL
    var assetName: String
    var changelog: String?      // release body (Markdown)
    var isPrerelease: Bool
}
```

**Versions are never compared as strings.** Add-on version schemes are inconsistent (`v426.4`, `12.1.12`, `r1234-alpha`). An update is available when the selected release has a **different `releaseID` and a later `publishedAt`** than the installed one.

---

## 6. Components

### 6.1 Flavor rules (`Flavor+Rules.swift`)

All per-flavor constants live in one table:

```swift
struct FlavorRules: Sendable {
    var interfaceRange: ClosedRange<Int>      // forever: 16000...19999
    var gameVersionRange: ClosedRange<Int>    // 1.60.0 ... 1.99.99, encoded as M*10000+m*100+p
    var tocSuffixes: [String]                 // ["Camelot", "Forever"] (matched with _ or -)
    var sharedTocSuffixes: [String]           // ["Mainline"]: valid only if interface is in range
    var releaseJSONFlavors: [String]          // ["forever"]
    var knownSubfolders: [String: String]     // "_classic_beta_": "wow_classic_beta"
}
```

When Forever launches and Blizzard picks a final folder and product code, this table is the only thing that changes.

### 6.2 `InstallationLocator`

Finds WoW installs and works out their flavor.

1. **Candidates:** run `mdfind "kMDItemCFBundleIdentifier == 'com.blizzard.worldofwarcraft'"`, take each result's parent folder, and also check `/Applications/World of Warcraft`. Users can always add a folder by hand.
2. **Subfolders:** for each `World of Warcraft/` folder, list its `_*_` subfolders that contain `Interface/` or a WoW `.app`.
3. **Flavor:** parse `World of Warcraft/.build.info`, map the subfolder to a product code, read its `Version`, and map that to a flavor using `gameVersionRange`. Fall back to the subfolder name, and then to asking the user.

`.build.info` and `mdfind` output are inputs only. Detection never writes anything.

### 6.3 Parsers (pure)

**`Toc`**
- Reads lines of the form `## Key: Value`. Strips a UTF-8 BOM, accepts CRLF, and treats keys as case-insensitive.
- `## Interface:` may be a comma-separated list (`120100, 16001`), so it's parsed into `[Int]`.
- Also reads `Title`, `Version`, `Notes`, `Author`, `Dependencies`/`RequiredDeps`, `OptionalDeps`, `X-Curse-Project-ID`, `X-WoWI-ID`, `X-Wago-ID` and `X-Website`.
- Strips colour codes (`|cff…|r`) from `Title` for display.

**`TocFileName`**
- Splits `BigWigs_Camelot.toc` into the add-on `BigWigs` and the suffix `Camelot`. Accepts both `_` and `-` separators.

**`ReleaseJSON`**
- Decodes the packager format shown in §2. `name` and `version` are optional because older packager versions omit them.

**`BuildInfo`**
- Parses the pipe-separated (BPSV) format. The header looks like `Name!TYPE:len|…`, and lines starting with `#` are comments.

### 6.4 `Source` protocol

```swift
protocol Source: Sendable {
    var id: SourceID { get }

    /// Turn user input ("owner/repo", a github.com URL) into a ref, or nil if it isn't ours.
    func parse(_ input: String) -> AddonRef?

    /// Newest release of `ref` that supports `flavor` on `channel`.
    func resolve(_ ref: AddonRef, flavor: Flavor, channel: Channel,
                 etag: String?) async throws -> ResolveResult
}

enum ResolveResult: Sendable {
    case notModified                       // 304: nothing new
    case release(ResolvedRelease, etag: String?)
}
```

Search is a separate protocol (`Catalogue`), because GitHub search comes from the CSV file, not the GitHub API.

### 6.5 `GitHubSource`

Requests:

- `GET https://api.github.com/repos/{owner}/{repo}/releases?per_page=10`
- Headers:
  - `Accept: application/vnd.github+json`
  - `X-GitHub-Api-Version: 2022-11-28`
  - `User-Agent: ForeverAddons/<version>`
  - `Authorization: Bearer <token>`, only if the user saved a token
  - `If-None-Match: <etag>`
- A **304** response doesn't count against the rate limit. Store the returned `ETag` on every 200.
- On **403/429** with `x-ratelimit-remaining: 0`, raise `.rateLimited(resetAt:)`. The UI then shows when checks can resume and suggests adding a token.

Release selection is done by `ReleaseSelector`, a pure function that takes the decoded releases:

1. Drop drafts. Drop prereleases unless `channel == .prerelease`. Walk releases newest first.
2. **If the release has a `release.json` asset:** download it with `browser_download_url`, which doesn't count against API quota, and cache it by asset id forever. Pick the entry whose `metadata` contains a Forever flavor and `nolib == false`, and match its `filename` to an asset. If no entry supports Forever, **move on to the next older release.** This handles authors who dropped Forever support and lets users stay on the last working version.
3. **Otherwise use the fallback:**
   1. Candidates are uploaded `.zip` assets whose names don't contain `-nolib`.
   2. Download each candidate in turn (most are under 5 MB) into the download cache.
   3. Inspect its TOCs as in §6.6, and accept the first one that supports Forever.
   4. *Later optimisation:* read just the zip's file listing with an HTTP `Range` request on the last ~25 KB, as instawow does.
4. If nothing matches, return `.noCompatibleRelease`. The UI shows "No Forever build yet".

### 6.6 Zip inspection — "does this zip support Forever?"

Given the zip's file listing:

1. Find add-on folders: top-level folders that contain `<Folder>/<Folder>[suffix].toc`.
2. If any TOC has a Forever suffix (`_Camelot`, `-Forever`, …), the zip supports Forever.
3. Otherwise read the add-on's `_Mainline` TOC, or its base TOC, and check whether any `Interface` value falls in `16000...19999`.

The same check is used when **adopting** add-ons a user installed by hand (§6.9), but there it runs on folders on disk instead of a zip.

### 6.7 `Downloader`

- Uses `URLSession` `download(from:)`, saving to `~/Library/Caches/<bundle-id>/downloads/<source>/<asset-id>-<name>.zip`.
- Runs up to 4 downloads at once (a `TaskGroup` with a limit). Shows progress through `URLSessionTaskDelegate`.
- Keeps the last 2 zips per add-on so rollback works without a network connection.

### 6.8 `Installer`

Installing is the riskiest operation, so it works like a transaction:

1. **Validate the zip** before touching `AddOns`:
   - Every entry path must resolve inside the extraction root. Reject `..`, absolute paths and symlinks (zip-slip).
   - There must be at least one top-level folder that contains a `.toc`.
   - Reject zips with stray top-level files. Ignore `__MACOSX/` and `.DS_Store`.
2. **Check folder ownership.** For each top-level folder `F` in the zip:
   - Owned by this add-on: replace it.
   - Owned by another managed add-on: **conflict**. Stop and report which add-on owns it.
   - Not owned by anyone, but `F` exists on disk: **unmanaged overwrite**. The UI must confirm. The CLI requires `--force`.
3. **Extract to a staging folder** on the same volume, using `FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: addonsDirectory, create: true)`. This keeps the later moves atomic renames.
4. **Swap folders:**
   - Move each existing `F` into a backup folder in the staging area, then move the new `F` into `AddOns/`.
   - Also move out any folders the *previous* version owned that the new version no longer ships.
   - If any step fails, put the backups back in reverse order and rethrow.
5. **Commit:** write the new `InstalledAddon` record, then delete the staging and backup folders.

**Uninstall** moves the add-on's folders to the Trash (`FileManager.trashItem`) instead of deleting them, then removes the record.

**WoW running:** if the client is running (check `NSRunningApplication` for bundle id `com.blizzard.worldofwarcraft`), warn that changes apply after `/reload` or a restart. Don't block the install.

### 6.9 `InstallStore`

- Stores one JSON file per installation at `~/Library/Application Support/<bundle-id>/installations/<installation-id>.json`.
- Writes are atomic (`Data.write(options: .atomic)`) and go through the `InstallStore` actor, so writes never overlap.
- The file has a `schemaVersion` number so its format can be migrated later.
- The store is **separate from `AddOns/`** and puts no marker files into the game folder.

**Reconciling** runs when the app launches and before any batch operation:

- A managed add-on's folders are missing from disk: mark it **missing**. Offer reinstall or forget.
- `AddOns/` has unmanaged folders: show them as **unmanaged**. For each, read its TOC and offer **adopt**:
  - If `X-Website` points to a GitHub repo, or the folder name matches a repo in the catalogue, suggest that `AddonRef`.
  - Adopting means resolving the latest release and running a normal install over the folder after the user confirms.
- Folders starting with `Blizzard_` are never touched or listed.

### 6.10 `AddonManager` (façade)

```swift
actor AddonManager {
    func installations() async throws -> [Installation]
    func addInstallation(at url: URL) async throws -> Installation

    func installed(in: Installation) async throws -> [AddonStatus]       // includes reconcile results
    func search(_ query: SearchQuery) -> AsyncStream<[SearchResult]>     // see §7.6
    func install(_ ref: AddonRef, into: Installation, channel: Channel) async throws -> InstalledAddon
    func checkForUpdates(in: Installation) async throws -> [AddonRef: UpdateState]
    func update(_ refs: [AddonRef], in: Installation) -> AsyncStream<OperationEvent>
    func uninstall(_ ref: AddonRef, from: Installation) async throws
    func rollback(_ ref: AddonRef, in: Installation) async throws
}
```

`OperationEvent` (queued, downloading(progress), installing, done, failed(error)) drives the progress UI and the CLI output.

---

## 7. Search

Search is a core feature. Users should be able to type "bags" or "boss mods" and get a list of add-ons that **work on Forever**, with an Install button on each result.

### 7.1 What can be searched

The search box searches several layers. Each layer is a `SearchProvider`, and their results are merged:

| Layer | Data | Cost | When it runs |
|---|---|---|---|
| **Installed** | `InstallStore` + unmanaged folders' TOCs | Local | Always, instantly. Matches show in an "Installed" section at the top. |
| **Catalogue** | `addons.csv` from `github-wow-addon-catalogue` (~2.4k repos) | One raw download per 24 h, no API quota | Always, instantly, in memory |
| **Known Forever list** | Our own cache of repos verified to support Forever (§7.3) | Local | Always. Used to boost and badge results. |
| **GitHub live search** | `GET /search/repositories` | **10 requests/min without a token**, 30/min with one | Only when the user clicks "Search GitHub for more", or catalogue results are fewer than 5. Debounced and never sent per keystroke. |
| **Direct reference** | Query looks like `owner/repo` or a `github.com/…` URL | 1 API call | Immediately. Shows a single "Install owner/repo" result. |

Later sources (WoWInterface's `filelist.json`, Tukui) plug in as more `SearchProvider`s. WoWInterface's list includes game-version data, so it can report Forever support directly.

### 7.2 Catalogue search

- `CatalogueSource` downloads `addons.csv` with an ETag and caches it for 24 hours. It parses the file into `[CatalogueEntry]` (name, full_name, description, url, last_updated, curse/wago/wowi ids, has_release_json).
- The parsed list is stored on disk in a compact binary format. A search index is built in memory when the app launches. At ~2.4k rows that takes a few milliseconds, so no database is needed.
- **Matching:**
  - The query and fields are case-folded and diacritic-folded.
  - Each query word must match a word in the name, repo owner/name or description.
  - The last word also matches as a prefix ("bag" finds "Baganator").
  - Common aliases are expanded from a small table (`dbm` → `DeadlyBossMods`, `bw` → `BigWigs`).
- **Ranking** (highest first):
  1. Exact name match.
  2. Name prefix match.
  3. Every word appears in the name.
  4. Match in the description.

  Within each tier, rank by Forever status (verified ✓, then unknown, then verified ✗), then `last_updated`.
- Unlike the UI, `addonctl search` waits for verification and prints the Forever status (§7.3).

### 7.3 Forever-support verification

The catalogue's `flavors` column is unreliable for Forever, so search results start out as **unknown** and are checked in the background:

1. After each search, the top ~15 visible results that aren't already cached are queued for verification.
2. Verification runs the normal resolver (`GitHubSource.resolve`, §6.5) without downloading the add-on. Usually that's one releases call plus the `release.json` asset, which doesn't count against API quota. Repos without a `release.json` are marked **unknown – needs download** rather than downloading their zips during search.
3. The result (`supported(version, releaseID)`, `unsupported`, `noReleases` or `unknown`) is cached per repo in `~/Library/Caches/<bundle-id>/forever-support.json` for 6 hours. ETags make re-checks free.
4. Rows update live as results arrive: ✓ Forever, — Not yet, or ? Unknown.
5. Verification runs at most 2 requests at a time. It stops early when `x-ratelimit-remaining` is low and keeps a reserve of 10 calls for update checks and installs.

A **"Forever only"** toggle (on by default) hides results that are verified unsupported. It keeps unknown results but shows them dimmed.

### 7.4 GitHub live search

- **Request:** `GET /search/repositories?q=<terms>+in:name,description+topic:wow-addon&sort=updated&per_page=30`.
- **If too few results:** run a second request with `topic:world-of-warcraft-addon`, then one without a topic filter but with `wow OR warcraft` added to the terms. About 1.6k repos use the `wow-addon` topic and about 800 use `world-of-warcraft-addon`.
- **Filtering:** drop archived repos and forks, then deduplicate against catalogue results.
- **Verification:** live results go through the same verification as catalogue results (§7.3).
- **Rate limits:**
  - If a request returns a rate-limit error, show "GitHub search limit reached, try again in Ns" and keep showing catalogue results.
  - Live search results are cached by query for 10 minutes.

### 7.5 Browse without a query

The Browse tab with an empty search box shows:
- **Popular on Forever:** verified add-ons from the known-Forever cache, sorted by GitHub stars.
- **Recently updated:** catalogue entries with the newest `last_updated` dates.
- **Category chips** (Boss mods, Bags, UI, Quests, Maps, Auction, Combat): each one runs a saved keyword search and is shown as a chip. They're defined in a bundled JSON file, so they can be adjusted without code changes.

### 7.6 API

```swift
struct SearchQuery: Sendable {
    var text: String
    var flavor: Flavor
    var foreverOnly: Bool = true
    var includeLiveGitHub: Bool = false
}

struct SearchResult: Sendable, Identifiable {
    var id: AddonRef
    var name: String
    var summary: String?
    var owner: String
    var stars: Int?
    var lastUpdated: Date?
    var installed: InstalledAddon?          // non-nil if already managed
    var support: SupportStatus              // .unknown, .checking, .supported(version), .unsupported
    var origin: Set<SearchOrigin>           // .installed, .catalogue, .github, .direct
}

protocol SearchProvider: Sendable {
    func search(_ query: SearchQuery) async throws -> [SearchResult]
}

// On AddonManager:
func search(_ query: SearchQuery) -> AsyncStream<[SearchResult]>   // re-emits as verification lands
```

`search` returns a stream. It emits local results immediately, then emits again as live results and verification statuses arrive. The SwiftUI list binds to the latest emitted list.

- Users can install directly from any search result.
- Users can always install from a `github.com/owner/repo` URL or an `owner/repo` string, even if no layer finds it.

---

## 8. App (SwiftUI)

```
┌────────────────┬───────────────────────────────────────────────────────┐
│ INSTALLATIONS  │  [Installed] [Browse]          ⟳ Check   ⬆ Update All │
│ ● Forever Beta │ ───────────────────────────────────────────────────── │
│   (+ Add…)     │  BigWigs        v426.3 → v426.4    GitHub   [Update]  │
│                │  DBM - Core     12.1.12            GitHub   ✓         │
│                │  BugSack        v11.2.5            GitHub   📌 pinned │
│                │  ── Unmanaged ──                                       │
│                │  Leatrix_Plus   1.60.08-forever    [Adopt…]            │
└────────────────┴───────────────────────────────────────────────────────┘
```

Browse tab:

```
┌────────────────┬───────────────────────────────────────────────────────┐
│ INSTALLATIONS  │  🔍 bags                         [✓ Forever only]     │
│ ● Forever Beta │  [Boss mods] [Bags] [UI] [Quests] [Maps] [Auction]    │
│                │ ── Installed ──────────────────────────────────────── │
│                │  Baganator      ✓ Forever   v720                Open  │
│                │ ── Results ────────────────────────────────────────── │
│                │  BetterBags     ✓ Forever   ★ 410   2d ago  [Install] │
│                │  Bagnon         ⋯ checking  ★ 300   5d ago  [Install] │
│                │  AdiBags        ? unknown   ★ 180   1mo ago [Install] │
│                │           [Search GitHub for more results]            │
└────────────────┴───────────────────────────────────────────────────────┘
```

- **Search box:** uses `.searchable` with a 250 ms debounce. ⌘F focuses it from any tab. On the Installed tab, the same box filters the installed list.
- Uses a `NavigationSplitView` with installations in the sidebar, an **Installed** / **Browse** list, and an inspector with the add-on's details, rendered changelog, owned folders, channel picker, pin toggle and rollback.
- View models are `@Observable @MainActor` and call `AddonManager`.
- **Settings:**
  - GitHub token, stored in the **Keychain** and never in the JSON store.
  - Default channel.
  - Check for updates on launch (default on).
  - Optional menu bar extra that shows an update count.
- Errors appear inline on the affected row. One failed add-on never aborts **Update All**.

### Sandboxing & distribution

- **v1 ships outside the App Store:** signed with Developer ID, notarized, not sandboxed. This keeps `mdfind` discovery and moving folders straightforward.
- The code still accesses folders through **security-scoped bookmarks**: folders are picked with `NSOpenPanel`, and bookmarks are stored per installation. Enabling the App Sandbox later is then a configuration change, not a rewrite.
- App self-updates (for example with Sparkle) are deferred.

---

## 9. CLI (`addonctl`)

The CLI is a full package manager, not a debugging tool. Anything you can do in the app, you can do from the terminal, and the reverse.

### 9.1 Principles

- **One core, one state.** The CLI and the app both use `AddonManager` and the same `InstallStore` in Application Support. An add-on installed from the terminal shows up in the app, and the reverse.
- **Safe to run alongside the app.**
  - Every write to the store takes an exclusive lock (`flock` on `installations/.lock`), so the CLI and the app never write at the same time.
  - Read-modify-write sequences, such as recording an install, hold the lock for the whole sequence.
  - The app watches the store folder for changes (a `DispatchSource` file-system event source) and reloads when the CLI changes something.
- **Shared credentials.**
  - The GitHub token lives in the Keychain, under service `com.andrewmiotke.ForeverAddons` and account `github-token`.
  - `KeychainStore` lives in `AddonKit` so both the app and the CLI can use it.
  - The `ADDONS_GITHUB_TOKEN` environment variable (falling back to `GITHUB_TOKEN`) overrides the stored token for one run, which is useful in CI.
- **Works for people and scripts.**
  - In a terminal: coloured tables, progress bars on stderr, and confirmation prompts.
  - When piped, or with `--json`: plain stable output on stdout and no prompts. Anything destructive requires `--yes`, otherwise the command fails.

### 9.2 Commands

Most commands mirror package managers people already know (brew, npm, apt), and familiar aliases are accepted.

| Command | Aliases | What it does |
|---|---|---|
| `search <query…>` | `s` | Same search as the Browse tab (§7). Waits for Forever verification of the top results before printing. `--github` adds live search, `--all` includes unsupported add-ons, `--limit N` caps results. |
| `info <ref>` | `show` | Details: description, latest Forever release and why it was chosen, installed version, owned folders, changelog (`--changelog`). |
| `install <ref…>` | `i`, `add` | Install one or more add-ons. Takes `owner/repo` or a GitHub URL; a plain name is looked up in the catalogue and must match exactly one add-on, otherwise the CLI asks which one. Options: `--prerelease`, `--version <tag>` (installs that tag and pins it), `--force` (overwrite unmanaged folders). |
| `remove <ref…>` | `rm`, `uninstall` | Uninstalls by moving folders to the Trash. Asks for confirmation unless `--yes`. |
| `update [<ref…>]` | `upgrade`, `up` | Updates everything (or just the listed add-ons). Skips pinned add-ons. `--dry-run` shows what would change. |
| `outdated` | | Lists add-ons with updates available. Exits with code 10 if anything is outdated (handy in scripts). |
| `list` | `ls` | Managed add-ons with version, source, channel and pin state. `--unmanaged` adds unmanaged folders, `--missing` shows only add-ons with missing folders. |
| `pin <ref…>` / `unpin <ref…>` | | Pin or unpin add-ons so `update` skips them. |
| `channel <ref> stable\|prerelease` | | Set an add-on's release channel. |
| `rollback <ref>` | | Reinstall the previous cached version. |
| `adopt [<folder> <ref>]` | | Start managing an unmanaged folder. With no arguments, walks through every unmanaged folder that has a suggested ref. |
| `resolve <ref>` | | Dry run: prints the full reasoning for which release and asset would be chosen. For debugging. |
| `installs` | | Lists detected installations and marks the default. Subcommands: `add <path>`, `remove <id>`, `default <id>`. |
| `export [--output file]` | | Writes the add-on list as `addons.json` (refs, channel, pinned and version for pinned add-ons) so a setup can be shared or restored. |
| `import <file>` | | Installs everything in an `addons.json` file. |
| `config get\|set\|unset <key>` | | Settings: `github-token` (stored in the Keychain; `set` reads from stdin so it isn't saved in shell history), `default-channel`, `default-install`. |
| `cache clear` / `cache info` | | Manage the download, catalogue and support caches. |
| `doctor` | | Checks the setup: whether WoW was detected and the Forever install is readable, store integrity (records whose folders are missing, folders claimed by two add-ons), GitHub reachability and rate limit, and whether a token is set. |

**`<ref>` forms:** `owner/repo`, `https://github.com/owner/repo`, `github:owner/repo` (a source prefix that becomes useful when WoWInterface is added), or the name of an add-on that's already installed (`addonctl rm bigwigs`).

### 9.3 Global options

```
-I, --install <id|path>   which installation to use (default: config default-install,
                          or the only Forever install; if there are several, ask)
    --json                machine-readable output on stdout, no prompts or colour
-y, --yes                 assume yes for confirmations
-q, --quiet / -v, --verbose
    --no-color            also honours NO_COLOR
```

### 9.4 Output

```
$ addonctl search boss
  NAME                 REPO                              FOREVER   UPDATED
  BigWigs              BigWigsMods/BigWigs               ✓ v426.4  2 days ago   (installed)
  DBM - Core           DeadlyBossMods/DeadlyBossMods     ✓ 12.1.12 3 days ago
  LittleWigs           BigWigsMods/LittleWigs            ? unknown 1 week ago

$ addonctl update
  BigWigs      v426.3 → v426.4   ━━━━━━━━━━━━━━━━━━━━ done
  Plater       v611   → v612     ━━━━━━━━━━━━━━━━━━━━ done
  BugSack      pinned, skipped
Updated 2 add-ons. WoW is running; type /reload to load them.
```

- With `--json`, every command prints one JSON document using the model types (`InstalledAddon`, `SearchResult`, `ResolvedRelease`, `UpdateState`), with ISO-8601 dates and a top-level `"schemaVersion": 1`. Errors go to stderr as `{"error": {"code": "...", "message": "..."}}`.
- **Exit codes:**
  - `0` success
  - `1` general error
  - `2` usage error
  - `3` partial failure (some add-ons failed during `update` or `install`)
  - `4` rate limited
  - `5` conflict or unmanaged folder (retry with `--force`)
  - `10` outdated (only from `outdated`)

### 9.5 Distribution

- **The app is the main way to install it.** Most people start with the app, so the CLI binary ships inside it at `ForeverAddons.app/Contents/Helpers/addonctl`. It's built as a separate Xcode target from `Sources/addonctl`.
  - **First launch:** the app asks once: *"Install the `addonctl` command-line tool?"*, with **Install** and **Not Now**.
  - **Install:** creates a symlink `/usr/local/bin/addonctl` → the binary inside the app, asking for an admin password. `/usr/local/bin` is on the default `PATH`. Because it's a symlink, updating the app also updates the CLI.
  - **Not Now:** the offer is not repeated.
  - **Settings ▸ Command-Line Tool** shows the status (not installed, installed, or pointing to another copy of the app) and has Install, Repair and Uninstall buttons. Uninstall only removes a link that points into a ForeverAddons app bundle.
- **Standalone.** `swift build -c release` works for development. A Homebrew tap (`brew install andrewmiotke/tap/addonctl`) comes later.
- **Shell completions.** ArgumentParser generates them: `addonctl --generate-completion-script zsh`. The completions also suggest installed add-on names for `<ref>`.
- **Name.** `addonctl` is a working name. A shorter name could replace it later; only the product name in `Package.swift` and the Helpers path need to change.

## 10. Testing

- **Unit tests (pure code):**
  - TOC parsing edge cases: BOM, CRLF, interface lists, colour codes.
  - TOC suffix splitting.
  - `release.json` decoding.
  - BPSV parsing.
  - Search ranking with a fixture catalogue CSV, checking that "dbm", "bag" and "boss" put the expected add-ons in the top 3.
  - `ReleaseSelector` against recorded GitHub API JSON fixtures, including no `release.json`, no Forever entry in the newest release, prerelease-only, drafts, and nolib assets.
- **Installer tests:**
  - Run against a temporary `AddOns` folder using tiny fixture zips: normal install, update that drops a folder, folder conflict, unmanaged overwrite, zip-slip rejection, and a failure partway through the swap that must restore the backups.
- **Network:**
  - `GitHubSource` takes an `HTTPClient` protocol, and tests use a stub that serves fixtures.
  - One opt-in integration test (`ADDONS_LIVE_TESTS=1`) resolves BigWigs and DBM for Forever against real GitHub.
- **Manual:**
  - Use `addonctl` against the real `_classic_beta_` folder, always on a copy at first.

---

## 11. Future work

- **More keyless sources:** WoWInterface and Tukui as additional `Source` implementations, plus `X-WoWI-ID` TOC hints for adopting add-ons.
- **CurseForge:** only if an API key is granted for this app. It would need a small proxy so the key isn't shipped in the app. It would also enable fingerprint matching (`POST /v1/fingerprints`) for adopting add-ons.
- **Wago:** let users paste their personal Wago token, as instawow does.
- **Dependencies:** warn when a `RequiredDeps` add-on is missing. Auto-install is hard because GitHub has no dependency metadata.
- **Other game versions:** add `FlavorRules` entries for mainline and classic.
- **Range-request zip inspection** (§6.5, step 3.4).
- **Import and export** of the add-on list, to share setups or move to another Mac.

---

## 12. Open questions

1. **Forever's launch folder and product code.** Currently `_classic_beta_` / `wow_classic_beta`. Update §6.1's table at launch, and detect flavor by game version rather than folder name so it keeps working either way.
2. **App name and bundle id.** `ForeverAddons` / `com.andrewmiotke.ForeverAddons` are placeholders.
3. **Contributing Forever data upstream.** Should we contribute Forever tags back to `github-wow-addon-catalogue`, or keep our own small list of known Forever repos?

---

## 13. Milestones

1. **M0 – Core parsing:** Package scaffold. `Toc`, `ReleaseJSON`, `BuildInfo` and `FlavorRules`, with tests.
2. **M1 – Resolve:** `GitHubSource` and `ReleaseSelector`. `addonctl resolve` works for BigWigs and DBM.
3. **M2 – Install + CLI:** `Downloader`, `Installer`, `InstallStore` (with locking), `InstallationLocator` and `AddonManager`. The core `addonctl` commands (`search`, `info`, `install`, `remove`, `update`, `outdated`, `list`, `pin`, `resolve`, `installs`) work on a copy of the beta folder, with `--json` and exit codes.
4. **M3 – App shell:** Xcode project with installations sidebar, Installed list and Update All.
5. **M4 – Search & adopt:** catalogue and installed search, Forever verification, GitHub live search, Browse tab, adopting unmanaged add-ons, settings and Keychain token. `addonctl search` should be working by M2, so ranking can be tuned early.
6. **M5 – Polish:** rollback, `export`/`import`, `doctor`, shell completions, bundling the CLI in the app with an install button, menu bar extra, notarized build.

---

## References

- instawow, a Python manager whose source this design borrows from: https://github.com/layday/instawow
- WowUp: https://github.com/WowUp/WowUp
- BigWigs packager (`release.json`, TOC suffix rules): https://github.com/BigWigsMods/packager
- GitHub add-on catalogue: https://github.com/layday/github-wow-addon-catalogue
- GitHub REST API (releases): https://docs.github.com/en/rest/releases
- TOC format: https://warcraft.wiki.gg/wiki/TOC_format

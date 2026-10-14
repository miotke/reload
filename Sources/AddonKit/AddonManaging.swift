import Foundation

/// The façade the app and CLI talk to (docs/architecture/core.md).
/// `AddonManager` is the only implementation; the protocol keeps the app and CLI decoupled from it.
public protocol AddonManaging: Sendable {
    func installations() async throws -> [Installation]
    /// Scans for WoW installs (Spotlight and `/Applications/World of Warcraft`), stores new ones,
    /// and returns every stored installation.
    @discardableResult
    func detectInstallations() async throws -> [Installation]
    func addInstallation(at url: URL) async throws -> Installation

    /// Managed and unmanaged add-ons, after reconciling the store with disk.
    func addons(in installation: Installation) async throws -> [AddonStatus]

    /// Emits local results immediately, then again as live results and support checks land.
    func search(_ query: SearchQuery, in installation: Installation) -> AsyncStream<[SearchResult]>

    /// Search with the caller's add-on list (no reconcile per query). Has a default.
    func search(_ query: SearchQuery, in installation: Installation, installed: [AddonStatus]) -> AsyncStream<[SearchResult]>

    /// Results plus whether the GitHub fallback is running and whether this is the last
    /// emission. Has a default.
    func searchUpdates(_ query: SearchQuery, in installation: Installation, installed: [AddonStatus]) -> AsyncStream<SearchUpdate>

    /// Popular, recently updated and category suggestions for an empty Browse tab.
    func browse(in installation: Installation) async -> BrowseContent

    func resolve(_ ref: AddonRef, for installation: Installation, channel: Channel) async throws -> ResolvedRelease

    /// `progress` reports download progress in `0...1`. With `allowFamilyFallback`, an add-on
    /// with no build for the installation's flavor installs its fallback family's build
    /// (`Flavor.fallbackFlavor`: the Retail build on Forever), recorded in
    /// `installedFlavorBuild`. Without it, that's `noCompatibleRelease`.
    @discardableResult
    func install(
        _ ref: AddonRef, into installation: Installation, channel: Channel, force: Bool, allowFamilyFallback: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledAddon

    /// Checks the support and available flavors of rows the user is looking at, quota-free
    /// (github.com `releases/latest` plus the tag's release.json, never the API): only refs
    /// without a fresh stored answer, at most 20 per call and 4 at a time, none already in
    /// flight. Skipped while github.com is pausing requests and on Low Data Mode. Answers are
    /// written through the store, so `MetadataDatabase.changes()` reports them. Returns the
    /// refs it checked. Has a default that checks nothing.
    @discardableResult
    func checkVisible(_ refs: [AddonRef], in installation: Installation) async -> [AddonRef]

    func checkForUpdates(in installation: Installation) async throws -> [AddonRef: UpdateState]
    func update(_ refs: [AddonRef], in installation: Installation) -> AsyncStream<OperationEvent>
    /// Installs releases an earlier check already found, without checking again. Empty does nothing.
    func update(releases: [ResolvedRelease], in installation: Installation) -> AsyncStream<OperationEvent>
    func uninstall(_ ref: AddonRef, from installation: Installation) async throws
    /// Reinstalls `previousRelease` from the download cache and pins the add-on.
    func rollback(_ ref: AddonRef, in installation: Installation) async throws

    func setPinned(_ pinned: Bool, for ref: AddonRef, in installation: Installation) async throws
    func setChannel(_ channel: Channel, for ref: AddonRef, in installation: Installation) async throws
    /// Start managing an unmanaged folder as `ref` (reinstalls over it after confirmation).
    func adopt(folder: String, as ref: AddonRef, in installation: Installation) async throws -> InstalledAddon
    /// Installs the release an `adoptionPreview` resolved, over the unmanaged folders it ships.
    func adopt(_ release: ResolvedRelease, in installation: Installation) async throws -> InstalledAddon
    /// Likely repositories for an unmanaged folder, best first, with reasons. Local only.
    func adoptionCandidates(folder: String, in installation: Installation) async -> [AdoptionCandidate]
    /// Resolves and downloads `ref`'s release for the flavor and lists the folders adopting
    /// it would replace. Spends no API quota for add-ons with a release.json.
    func adoptionPreview(for ref: AddonRef, folders: [String], in installation: Installation) async throws -> AdoptionPreview
    /// Moves unmanaged folders to the Trash; refuses `Blizzard_*`, managed and unknown folders.
    @discardableResult
    func removeUnmanaged(folders: [String], from installation: Installation) async throws -> [String]

    /// Call after the GitHub token in the Keychain changes.
    func tokenDidChange() async

    /// Every add-on source in display order, with whether search and Browse use it
    /// (docs/features/sources.md). Has a default that reports every source on.
    func sources() async -> [SourceSetting]
    /// Turns a source's search and Browse results on or off; installed add-ons from it keep
    /// their update checks. Shared with `reload`. Reported as a `.catalogue` change. Has a
    /// default that does nothing.
    func setSource(_ source: SourceID, enabled: Bool) async throws
    /// Hosted sources that are on but have no listing yet. Search never downloads one; the
    /// next `refresh`, even inside its 2-hour window, does. Has a default that reports none.
    func missingListings() async -> [SourceID]

    /// API quota, search quota and github.com pause state, from stored state only (no
    /// network). Has a default that reports nothing known.
    func gitHubStatus() async -> GitHubStatus

    /// README, screenshots, stats and latest version for the inspector. Cached on disk;
    /// spends no API quota. `latestChangelog` is filled only when the notes are stored.
    func details(for ref: AddonRef, in installation: Installation) async throws -> AddonDetails

    /// The latest stable release's notes, on demand: stored by tag, else one API call (no
    /// zip downloads). Nil when the repo has no releases.
    func releaseNotes(for ref: AddonRef, in installation: Installation) async throws -> (version: String, publishedAt: Date?, markdown: String)?

    /// Seeds and refreshes metadata: catalogue, update checks for installed add-ons, and
    /// flavor-support checks for catalogue add-ons. Without `force`, finishes immediately
    /// (with cached update states) if the last refresh was recent. Emits `.finished` last.
    func refresh(in installation: Installation, force: Bool) -> AsyncStream<RefreshProgress>

    /// When `refresh` last completed for `installation`, or nil if it never has.
    func lastRefresh(in installation: Installation) async -> Date?

    // MARK: Observing stored data (so the app never reaches into the database or store)

    /// Commits to the metadata database made by this process, as kinds plus affected repos.
    func metadataChanges() -> AsyncStream<MetadataChange>
    /// Changes when any process (e.g. `reload`) commits to the metadata database.
    func metadataVersion() async -> Int64?
    /// The install store's folder, for watching changes made by other processes.
    var storeDirectory: URL { get }
    /// Stored support and available flavors for `refs`, without touching the network.
    func storedAvailability(for refs: [AddonRef], in installation: Installation) async -> [AddonRef: StoredAvailability]
}

extension AddonManaging {
    /// Search with an add-on list the caller already has. The default ignores `installed`
    /// and reconciles; `AddonManager` uses it as given.
    public func search(_ query: SearchQuery, in installation: Installation, installed: [AddonStatus]) -> AsyncStream<[SearchResult]> {
        search(query, in: installation)
    }

    /// Search results plus whether a GitHub live search is running. The default wraps
    /// `search(_:in:installed:)` and never reports one.
    public func searchUpdates(_ query: SearchQuery, in installation: Installation, installed: [AddonStatus]) -> AsyncStream<SearchUpdate> {
        let results = search(query, in: installation, installed: installed)
        return AsyncStream { continuation in
            let task = Task {
                var last: [SearchResult] = []
                for await batch in results {
                    last = batch
                    continuation.yield(SearchUpdate(results: batch))
                }
                continuation.yield(SearchUpdate(results: last, isComplete: true))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @discardableResult
    public func install(_ ref: AddonRef, into installation: Installation, channel: Channel = .stable, force: Bool = false) async throws -> InstalledAddon {
        try await install(ref, into: installation, channel: channel, force: force, allowFamilyFallback: false, progress: { _ in })
    }

    /// Installs the installation's own build only.
    @discardableResult
    public func install(
        _ ref: AddonRef, into installation: Installation, channel: Channel, force: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledAddon {
        try await install(ref, into: installation, channel: channel, force: force, allowFamilyFallback: false, progress: progress)
    }

    @discardableResult
    public func checkVisible(_ refs: [AddonRef], in installation: Installation) async -> [AddonRef] { [] }

    public func gitHubStatus() async -> GitHubStatus { GitHubStatus() }

    public func sources() async -> [SourceSetting] {
        SourceID.allCases.map { SourceSetting(source: $0, isEnabled: true) }
    }

    public func setSource(_ source: SourceID, enabled: Bool) async throws {}

    public func missingListings() async -> [SourceID] { [] }
}

/// GitHub quota and backoff state, as last reported by GitHub. Nil fields mean unknown.
public struct GitHubStatus: Sendable, Hashable {
    /// REST API (`core`): 60 an hour without a token, 5,000 with one.
    public var api: RateLimitState?
    /// Search API: 10 a minute without a token, 30 with one.
    public var search: RateLimitState?
    /// The API limit for the current token state (60 or 5,000).
    public var apiLimit: Int?
    public var hasToken: Bool
    /// While set and in the future, quota-free github.com requests are paused (after a 429/403).
    public var webPausedUntil: Date?

    public init(api: RateLimitState? = nil, search: RateLimitState? = nil, apiLimit: Int? = nil, hasToken: Bool = false, webPausedUntil: Date? = nil) {
        self.api = api
        self.search = search
        self.apiLimit = apiLimit
        self.hasToken = hasToken
        self.webPausedUntil = webPausedUntil
    }
}

/// What a metadata commit touched, in terms the UI understands.
public struct MetadataChange: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// Support verdicts or available flavors.
        case support
        /// Catalogue rows: names, summaries, dates, stars.
        case catalogue
        /// README, screenshots, release notes.
        case details
    }

    public var kinds: Set<Kind>
    /// Affected repos; empty means many or unknown.
    public var refs: Set<AddonRef>

    public init(kinds: Set<Kind>, refs: Set<AddonRef>) {
        self.kinds = kinds
        self.refs = refs
    }
}

/// A repo's stored availability for one installation's flavor.
public struct StoredAvailability: Sendable, Hashable {
    public var support: SupportStatus?
    /// Nil when not checked yet.
    public var availableFlavors: Set<Flavor>?

    public init(support: SupportStatus?, availableFlavors: Set<Flavor>?) {
        self.support = support
        self.availableFlavors = availableFlavors
    }
}

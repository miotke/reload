import Foundation

/// The façade the app and CLI talk to (docs/design.md §6.10).
/// `AddonManager` is the real implementation; the app's previews use a mock.
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

    /// `progress` reports download progress in `0...1`.
    @discardableResult
    func install(
        _ ref: AddonRef, into installation: Installation, channel: Channel, force: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledAddon

    func checkForUpdates(in installation: Installation) async throws -> [AddonRef: UpdateState]
    func update(_ refs: [AddonRef], in installation: Installation) -> AsyncStream<OperationEvent>
    func uninstall(_ ref: AddonRef, from installation: Installation) async throws
    /// Reinstalls `previousRelease` from the download cache and pins the add-on.
    func rollback(_ ref: AddonRef, in installation: Installation) async throws

    func setPinned(_ pinned: Bool, for ref: AddonRef, in installation: Installation) async throws
    func setChannel(_ channel: Channel, for ref: AddonRef, in installation: Installation) async throws
    /// Start managing an unmanaged folder as `ref` (reinstalls over it after confirmation).
    func adopt(folder: String, as ref: AddonRef, in installation: Installation) async throws -> InstalledAddon

    /// Call after the GitHub token in the Keychain changes.
    func tokenDidChange() async

    /// README, screenshots, stats and latest release for the inspector. Cached on disk.
    func details(for ref: AddonRef, in installation: Installation) async throws -> AddonDetails

    /// Seeds and refreshes metadata: catalogue, update checks for installed add-ons, and
    /// flavor-support checks for catalogue add-ons. Without `force`, finishes immediately
    /// (with cached update states) if the last refresh was recent. Emits `.finished` last.
    func refresh(in installation: Installation, force: Bool) -> AsyncStream<RefreshProgress>

    /// When `refresh` last completed for `installation`, or nil if it never has.
    func lastRefresh(in installation: Installation) async -> Date?
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
        try await install(ref, into: installation, channel: channel, force: force, progress: { _ in })
    }
}

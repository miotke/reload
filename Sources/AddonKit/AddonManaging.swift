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
}

extension AddonManaging {
    @discardableResult
    public func install(_ ref: AddonRef, into installation: Installation, channel: Channel = .stable, force: Bool = false) async throws -> InstalledAddon {
        try await install(ref, into: installation, channel: channel, force: force, progress: { _ in })
    }
}

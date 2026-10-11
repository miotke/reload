import Foundation

/// The façade the app and CLI talk to (DESIGN.md §6.10).
/// `AddonManager` is the real implementation; the app's previews use a mock.
public protocol AddonManaging: Sendable {
    func installations() async throws -> [Installation]
    func addInstallation(at url: URL) async throws -> Installation

    /// Managed and unmanaged add-ons, after reconciling the store with disk.
    func addons(in installation: Installation) async throws -> [AddonStatus]

    /// Emits local results immediately, then again as live results and support checks land.
    func search(_ query: SearchQuery, in installation: Installation) -> AsyncStream<[SearchResult]>

    func resolve(_ ref: AddonRef, for installation: Installation, channel: Channel) async throws -> ResolvedRelease

    @discardableResult
    func install(_ ref: AddonRef, into installation: Installation, channel: Channel, force: Bool) async throws -> InstalledAddon

    func checkForUpdates(in installation: Installation) async throws -> [AddonRef: UpdateState]
    func update(_ refs: [AddonRef], in installation: Installation) -> AsyncStream<OperationEvent>
    func uninstall(_ ref: AddonRef, from installation: Installation) async throws
    func rollback(_ ref: AddonRef, in installation: Installation) async throws

    func setPinned(_ pinned: Bool, for ref: AddonRef, in installation: Installation) async throws
    func setChannel(_ channel: Channel, for ref: AddonRef, in installation: Installation) async throws
    /// Start managing an unmanaged folder as `ref` (reinstalls over it after confirmation).
    func adopt(folder: String, as ref: AddonRef, in installation: Installation) async throws -> InstalledAddon
}

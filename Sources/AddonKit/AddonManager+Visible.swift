import Foundation
import Network
import Synchronization

/// Checks for the Browse rows the user is looking at (docs/features/refresh.md#visible-row-checks).
/// Quota-free only: every check is a background `latestRelease`, which goes to github.com
/// (`HEAD releases/latest`, then the tag's release.json if it isn't stored) and never to the API.
extension AddonManager {
    /// Refs checked per call at most; the rest wait for the next call.
    public static let visibleCheckLimit = 20
    /// Checks in flight at once, the same github.com politeness as the refresh.
    public static let visibleCheckConcurrency = 4

    @discardableResult
    public func checkVisible(_ refs: [AddonRef], in installation: Installation) async -> [AddonRef] {
        let flavor = installation.flavor
        guard !networkIsConstrained(), !(await github.webIsPaused()) else { return [] }
        var seen = Set<String>()
        var targets: [AddonRef] = []
        for ref in refs where ref.source == .github && targets.count < Self.visibleCheckLimit {
            let key = ref.identifier.lowercased()
            guard seen.insert(key).inserted, !visibleInFlight.contains(key) else { continue }
            // Claimed before the await, so a call that runs meanwhile skips it.
            visibleInFlight.insert(key)
            if await github.hasFreshAnswer(for: ref, flavor: flavor) {
                visibleInFlight.remove(key)
                continue
            }
            targets.append(ref)
        }
        let keys = Set(targets.map { $0.identifier.lowercased() })
        defer { visibleInFlight.subtract(keys) }
        guard !targets.isEmpty else { return [] }

        let github = self.github
        await withTaskGroup(of: Void.self) { group in
            var queue = targets[...]
            func addNext() {
                guard let ref = queue.popFirst() else { return }
                group.addTask {
                    _ = await github.latestRelease(for: ref, flavor: flavor, policy: .revalidateIfStale, background: true)
                }
            }
            for _ in 0..<Self.visibleCheckConcurrency { addNext() }
            while await group.next() != nil {
                // A new query cancels the caller; github.com pushing back stops the rest too.
                if Task.isCancelled { break }
                if await github.webIsPaused() { break }
                addNext()
            }
        }
        return targets
    }

    func setNetworkConstrained(_ isConstrained: @escaping @Sendable () -> Bool) {
        networkIsConstrained = isConstrained
    }
}

/// Whether the current network path is constrained (Low Data Mode), kept current by an
/// `NWPathMonitor` started on first use.
final class NetworkPathMonitor: Sendable {
    static let shared = NetworkPathMonitor()

    private let monitor = NWPathMonitor()
    private let constrained = Mutex(false)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.constrained.withLock { $0 = path.isConstrained }
        }
        monitor.start(queue: DispatchQueue(label: "ForeverAddons.network-path", qos: .utility))
    }

    var isConstrained: Bool { constrained.withLock { $0 } }
}

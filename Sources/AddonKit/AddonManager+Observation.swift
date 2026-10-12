import Foundation

/// `AddonManaging`'s observation API: the app watches stored data through these instead of
/// reaching into `MetadataDatabase`, `InstallStore` or `SupportCache` (docs/architecture/core.md).
extension AddonManager {
    public nonisolated func metadataChanges() -> AsyncStream<MetadataChange> {
        AsyncStream { continuation in
            let task = Task {
                for await change in await database.changes() {
                    continuation.yield(MetadataChange(
                        kinds: Self.kinds(for: change.tables),
                        refs: Set(change.repos.map { AddonRef(source: .github, identifier: $0) })
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func kinds(for tables: Set<String>) -> Set<MetadataChange.Kind> {
        var kinds = Set<MetadataChange.Kind>()
        if !tables.isDisjoint(with: ["support", "repo_meta", "release_json"]) { kinds.insert(.support) }
        if tables.contains("catalogue") { kinds.insert(.catalogue) }
        if tables.contains("details") { kinds.insert(.details) }
        return kinds
    }

    public func metadataVersion() async -> Int64? {
        try? await database.dataVersion()
    }

    public nonisolated var storeDirectory: URL { store.storeDirectory }

    public func storedAvailability(for refs: [AddonRef], in installation: Installation) async -> [AddonRef: StoredAvailability] {
        var result: [AddonRef: StoredAvailability] = [:]
        for ref in refs {
            result[ref] = StoredAvailability(
                support: await supportCache.status(for: ref, flavor: installation.flavor),
                availableFlavors: await supportCache.availableFlavors(for: ref)
            )
        }
        return result
    }
}

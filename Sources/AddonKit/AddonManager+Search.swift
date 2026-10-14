import Foundation

/// Search, Browse and stored catalogue lookups, all local first (docs/features/search.md).
extension AddonManager {
    /// Reconciles the installation with disk first; pass `installed` to skip that per query.
    public nonisolated func search(_ query: SearchQuery, in installation: Installation) -> AsyncStream<[SearchResult]> {
        AsyncStream { continuation in
            let task = Task {
                let installed = (try? await self.addons(in: installation)) ?? []
                for await results in self.searchCoordinator.search(query, installed: installed) {
                    continuation.yield(results)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Search with the caller's current add-on list, so typing doesn't rescan `AddOns/`.
    public nonisolated func search(_ query: SearchQuery, in installation: Installation, installed: [AddonStatus]) -> AsyncStream<[SearchResult]> {
        searchCoordinator.search(query, installed: installed)
    }

    /// Like `search(_:in:installed:)`, but also reports when a GitHub live search is running.
    public nonisolated func searchUpdates(_ query: SearchQuery, in installation: Installation, installed: [AddonStatus]) -> AsyncStream<SearchUpdate> {
        searchCoordinator.searchUpdates(query, installed: installed)
    }

    /// Every flavor each repo's latest release ships, as stored; refs nobody has checked are
    /// left out. Local only.
    public func availableFlavors(for refs: [AddonRef]) async -> [AddonRef: Set<Flavor>] {
        guard !refs.isEmpty else { return [:] }
        let stored = await supportCache.allAvailableFlavors()
        var out: [AddonRef: Set<Flavor>] = [:]
        for ref in refs {
            if let flavors = stored[ref.key.lowercased()] { out[ref] = flavors }
        }
        return out
    }

    /// The stored catalogue row for `ref` (including repos found by live search). Local only.
    public func catalogueEntry(for ref: AddonRef) async -> CatalogueEntry? {
        await catalogue.entry(for: ref)
    }

    public func browse(in installation: Installation) async -> BrowseContent {
        let browse = await searchCoordinator.browse(flavor: installation.flavor)
        let installed = Dictionary(
            ((try? await store.addons(in: installation)) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let markInstalled = { (results: [SearchResult]) in
            results.map { result in
                var result = result
                result.installed = installed[result.id]
                result.origin.formUnion(result.installed == nil ? [] : [.installed])
                return result
            }
        }
        return BrowseContent(popular: markInstalled(browse.popular), recent: markInstalled(browse.recent), categories: browse.categories)
    }
}

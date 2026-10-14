import AddonKit
import Foundation

/// Follows the app's own metadata writes (refresh, details, live search, visible-row checks)
/// through `metadataChanges()` and patches the affected Browse rows, at most every
/// `interval` (docs/app/live-data.md). Writes by other processes are caught by
/// `BrowseModel.reloadMetadata`.
@MainActor
final class LiveMetadata {
    private weak var browse: BrowseModel?
    private let manager: any AddonManaging
    /// Lower-cased `AddonRef.key` of rows changed since the last patch.
    private var changedRepos: Set<String> = []
    private var needsBrowseReload = false
    private var patchTask: Task<Void, Never>?
    private var lastPatch: ContinuousClock.Instant?
    /// Database changes are applied at most this often; a refresh writes a verdict per repo.
    static let interval: Duration = .milliseconds(500)

    init(browse: BrowseModel, manager: any AddonManaging) {
        self.browse = browse
        self.manager = manager
        let changes = manager.metadataChanges()
        Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                self.receive(change)
            }
        }
    }

    private func receive(_ change: MetadataChange) {
        guard !change.kinds.isDisjoint(with: [.support, .catalogue]) else { return }
        if change.refs.isEmpty {
            needsBrowseReload = true
            if change.kinds.contains(.catalogue) { browse?.catalogueDidChange() }
        } else {
            let repos = Set(change.refs.map { $0.key.lowercased() })
            changedRepos.formUnion(repos)
            // Names, summaries and dates come from the catalogue; re-read the home lists if
            // one of their rows changed. Search results already carry fresh catalogue data.
            if change.kinds.contains(.catalogue), !repos.isDisjoint(with: homeRepos) { needsBrowseReload = true }
        }
        schedulePatch()
    }

    private var homeRepos: Set<String> {
        let content = browse?.content
        return Set(((content?.popular ?? []) + (content?.recent ?? [])).map { $0.id.key.lowercased() })
    }

    /// Applies pending changes now if the last patch was long enough ago, else when it is.
    private func schedulePatch() {
        guard patchTask == nil, needsBrowseReload || !changedRepos.isEmpty else { return }
        patchTask = Task { [weak self] in
            if let last = self?.lastPatch {
                try? await Task.sleep(until: last + Self.interval, clock: .continuous)
            }
            guard let self else { return }
            self.lastPatch = .now
            let repos = self.changedRepos
            let reload = self.needsBrowseReload
            self.changedRepos = []
            self.needsBrowseReload = false
            if reload, let browse = self.browse, browse.content != nil { await browse.loadBrowse() }
            await self.patchSupport(for: repos)
            self.patchTask = nil
            // Changes that arrived while this one ran.
            self.schedulePatch()
        }
    }

    /// Re-reads the stored verdicts and available flavors of listed rows in `repos`
    /// (lower-cased `AddonRef.key`), including those `checkVisible` just wrote.
    func patchSupport(for repos: Set<String>) async {
        guard let browse, !repos.isEmpty else { return }
        let refs = browse.listedRefs.filter { repos.contains($0.key.lowercased()) }
        guard !refs.isEmpty else { return }
        let stored = await manager.storedAvailability(for: Array(refs), in: browse.installation)
        let answers = stored.filter { $0.value.support != nil || $0.value.availableFlavors != nil }
        if !answers.isEmpty { browse.applyStored(answers) }
    }
}

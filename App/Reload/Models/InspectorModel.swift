import AddonKit
import Foundation
import Observation

/// The inspector of one installation: what's selected in each tab, and the details (README,
/// screenshots, stats) loaded for it, kept for the most recently viewed add-ons.
@Observable @MainActor
final class InspectorModel {
    let installation: Installation
    private let manager: any AddonManaging
    /// Selecting a row opens the inspector; the app owns whether it's shown.
    @ObservationIgnored var didSelect: (@MainActor () -> Void)?
    /// Opening details refreshes that one repo in the core; Browse shows its fresh games.
    @ObservationIgnored var didLoadAvailability: (@MainActor (AddonRef, StoredAvailability) -> Void)?

    /// Selection in the Installed tab.
    var selectedAddonID: AddonStatus.ID? {
        didSet { if selectedAddonID != nil { didSelect?() } }
    }
    /// Selection in the Browse tab.
    var selectedBrowseID: BrowseRow.ID? {
        didSet { if selectedBrowseID != nil { didSelect?() } }
    }

    /// Fetched once per add-on per session, for the `detailsLimit` most recently viewed
    /// (each holds a parsed README); the core also caches them on disk.
    private(set) var details: [AddonRef: DetailsState] = [:]
    @ObservationIgnored private var detailsUse = RecentKeys<AddonRef>(limit: InspectorModel.detailsLimit)
    @ObservationIgnored private var detailLoads: [AddonRef: UUID] = [:]
    static let detailsLimit = 20

    init(installation: Installation, manager: any AddonManaging) {
        self.installation = installation
        self.manager = manager
    }

    func clearSelection() {
        if selectedAddonID != nil { selectedAddonID = nil }
        if selectedBrowseID != nil { selectedBrowseID = nil }
    }

    /// Fetches details unless they're already loaded. Runs in the caller's task, so the
    /// inspector cancels it when the selection changes; a cancelled load leaves no state
    /// behind, and only the newest load for a ref may write its result.
    func loadDetails(for ref: AddonRef, force: Bool = false) async {
        if case .loaded? = details[ref], !force {
            _ = detailsUse.use(ref)
            return
        }
        let token = UUID()
        detailLoads[ref] = token
        setDetails(.loading, for: ref)
        let outcome: DetailsState?
        do {
            let fetched = try await manager.details(for: ref, in: installation)
            let readme = fetched.readme ?? ""
            // Relative links in a README resolve against the repository.
            let base = fetched.repositoryURL.appending(path: "blob/HEAD/")
            let blocks = await Task.detached(priority: .userInitiated) { MarkdownParser.renderedBlocks(from: readme, baseURL: base) }.value
            outcome = Task.isCancelled ? nil : .loaded(fetched, readme: blocks)
        } catch {
            outcome = Task.isCancelled || error is CancellationError ? nil : .failed(error.localizedDescription)
        }
        guard detailLoads[ref] == token else { return }
        detailLoads[ref] = nil
        setDetails(outcome, for: ref)
        if let details = outcome?.details {
            didLoadAvailability?(ref, StoredAvailability(support: details.support, availableFlavors: details.availableFlavors))
        }
    }

    /// Fetches the latest release's notes (one GitHub API call unless stored) into the
    /// loaded details. Throws so the button can show what went wrong.
    func loadReleaseNotes(for ref: AddonRef) async throws {
        let notes = try await manager.releaseNotes(for: ref, in: installation)
        guard case .loaded(var loaded, let readme)? = details[ref] else { return }
        // No releases at all reads as "no notes", not as a failure.
        loaded.latestChangelog = notes?.markdown ?? ""
        if let notes {
            if loaded.latestVersion == nil { loaded.latestVersion = notes.version }
            loaded.latestPublishedAt = notes.publishedAt ?? loaded.latestPublishedAt
        }
        setDetails(.loaded(loaded, readme: readme), for: ref)
    }

    /// Refs whose details are loaded; their games follow the metadata database like Browse rows.
    var loadedRefs: Set<AddonRef> {
        Set(details.compactMap { $0.value.details == nil ? nil : $0.key })
    }

    /// Patches loaded details with fresh stored availability, so installing an add-on (which
    /// records the flavors its TOCs ship) updates the header without refetching.
    func applyStored(_ answers: [AddonRef: StoredAvailability]) {
        for (ref, answer) in answers {
            guard case .loaded(var loaded, let readme)? = details[ref] else { continue }
            let before = loaded
            if let support = answer.support { loaded.support = support }
            if let flavors = answer.availableFlavors { loaded.availableFlavors = flavors }
            if loaded != before { details[ref] = .loaded(loaded, readme: readme) }
        }
    }

    // MARK: Optional parts

    /// Optional parts of the managed add-ons recently shown, by installed ref
    /// (docs/app/optional-parts.md). Each list is its own object, so reloading one re-renders
    /// only its section.
    private(set) var optionalParts: [AddonRef: OptionalPartsList] = [:]
    @ObservationIgnored private var partsUse = RecentKeys<AddonRef>(limit: InspectorModel.detailsLimit)
    @ObservationIgnored private var partsReload: Task<Void, Never>?
    @ObservationIgnored private var partsReloadPending = false

    /// Opening a managed add-on: the stored answer first (no network), then the core
    /// revalidates it if stale, which opening an add-on is allowed to do. Then follows the
    /// app's own metadata writes for the repo until the inspector cancels the task.
    func loadOptionalParts(for ref: AddonRef) async {
        let list: OptionalPartsList
        if let existing = optionalParts[ref] {
            list = existing
        } else {
            list = OptionalPartsList(ref: ref)
            optionalParts[ref] = list
        }
        for evicted in partsUse.use(ref) { optionalParts[evicted] = nil }
        await load(list, policy: .preferStored)
        guard !Task.isCancelled else { return }
        await load(list, policy: .revalidateIfStale)
        let repo = ref.repo.key.lowercased()
        for await change in manager.metadataChanges() {
            guard change.refs.isEmpty || change.refs.contains(where: { $0.repo.key.lowercased() == repo }) else { continue }
            await load(list, policy: .preferStored)
        }
    }

    /// The install store or another process's metadata changed: re-reads the stored parts of
    /// every list shown (local), once however many changes arrive meanwhile.
    @discardableResult
    func reloadOptionalParts() -> Task<Void, Never>? {
        guard !optionalParts.isEmpty else { return nil }
        partsReloadPending = true
        if let partsReload { return partsReload }
        let task = Task {
            while partsReloadPending {
                partsReloadPending = false
                for list in optionalParts.values { await load(list, policy: .preferStored) }
            }
            partsReload = nil
        }
        partsReload = task
        return task
    }

    private func load(_ list: OptionalPartsList, policy: CachePolicy) async {
        do {
            let parts = try await manager.optionalParts(of: list.ref, in: installation, policy: policy)
            guard !Task.isCancelled else { return }
            list.apply(parts)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            list.fail(error.localizedDescription)
        }
    }

    /// Stores `state` for `ref`, dropping the least recently viewed beyond `detailsLimit`.
    func setDetails(_ state: DetailsState?, for ref: AddonRef) {
        details[ref] = state
        guard state != nil else {
            detailsUse.remove(ref)
            return
        }
        for evicted in detailsUse.use(ref) { details[evicted] = nil }
    }
}

/// One managed add-on's optional parts, as rows. Empty until the core reports some, and then
/// the inspector shows the section.
@Observable @MainActor
final class OptionalPartsList {
    let ref: AddonRef
    private(set) var rows: [OptionalPartRow] = []
    /// The last listing failed; the rows already shown stay.
    private(set) var error: String?

    init(ref: AddonRef) {
        self.ref = ref
    }

    func apply(_ parts: [OptionalPart]) {
        let rows = parts.map(OptionalPartRow.init)
        if rows != self.rows { self.rows = rows }
        if error != nil { error = nil }
    }

    func fail(_ message: String) {
        if error != message { error = message }
    }
}

enum DetailsState {
    case loading
    case loaded(AddonDetails, readme: [MarkdownBlock])
    case failed(String)

    var details: AddonDetails? {
        if case .loaded(let details, _) = self { details } else { nil }
    }
}

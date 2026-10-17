import AddonKit
import Foundation

/// One installation's models, wired together. Views take the part they need as a property
/// (docs/app/layout.md#models); this type only owns them and connects their hooks.
@MainActor
final class InstallationModel {
    let installation: Installation
    /// Add-ons, update states and the Installed table.
    let installed: InstalledModel
    /// Search, home lists, the Browse table and live patches.
    let browse: BrowseModel
    /// Selection and loaded details.
    let inspector: InspectorModel
    /// Checks, installs, updates and per-row progress.
    let queue: UpdateQueue

    init(installation: Installation, manager: any AddonManaging, reportError: @escaping @MainActor (String) -> Void) {
        self.installation = installation
        let installed = InstalledModel(installation: installation, manager: manager, reportError: reportError)
        let browse = BrowseModel(installation: installation, manager: manager, installed: installed)
        let inspector = InspectorModel(installation: installation, manager: manager)
        let queue = UpdateQueue(installation: installation, manager: manager, installed: installed)
        self.installed = installed
        self.browse = browse
        self.inspector = inspector
        self.queue = queue

        installed.didChangeInstallState = { [weak browse] in browse?.rebuildRows() }
        queue.didInstall = { [weak browse] addon in browse?.markInstalled(addon) }
        queue.didFinishRefresh = { [weak browse] in
            if let browse, browse.content != nil { await browse.loadBrowse() }
        }
        browse.watchedRefs = { [weak inspector] in inspector?.loadedRefs ?? [] }
        browse.didApplyStored = { [weak inspector] answers in inspector?.applyStored(answers) }
        browse.isRefreshing = { [weak queue] in queue?.isRefreshing ?? false }
        browse.selectAfterSearch = { [weak inspector] id in inspector?.selectedBrowseID = id }
        inspector.didLoadAvailability = { [weak browse] ref, availability in browse?.applyStored([ref: availability]) }
    }
}

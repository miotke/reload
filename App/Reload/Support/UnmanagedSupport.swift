import AddonKit
import Foundation

// Pure pieces of the unmanaged-folder UI (Adopt sheet, Move to Trash), kept out of the views
// so tests can check them (docs/app/layout.md).

/// An unmanaged folder (or group) offered for adoption.
struct AdoptTarget: Identifiable {
    var unmanaged: UnmanagedFolder
    var folder: String { unmanaged.folder }
    var id: String { AddonStatus.unmanagedID(unmanaged.folder) }

    init(_ unmanaged: UnmanagedFolder) {
        self.unmanaged = unmanaged
    }

    init?(_ status: AddonStatus) {
        guard let unmanaged = status.unmanagedFolder else { return nil }
        self.init(unmanaged)
    }
}

/// Something to remove after the user confirms. It drives the window's confirmation dialog,
/// so context menus (hosted by AppKit) only have to set it.
enum RemovalRequest: Identifiable, Equatable {
    /// `dependents`: managed add-ons that stop loading without it (empty when Settings doesn't warn).
    case managed(InstalledAddon, dependents: [InstalledAddon] = [])
    /// A managed add-on whose folders were all deleted outside Reload: removing it only
    /// forgets it (the core's uninstall skips folders that are gone).
    case forget(InstalledAddon)
    case unmanaged(UnmanagedFolder)

    var id: String {
        switch self {
        case .managed(let addon, _), .forget(let addon): addon.id.description
        case .unmanaged(let folder): AddonStatus.unmanagedID(folder.folder)
        }
    }

    var title: String {
        switch self {
        case .managed(let addon, _): "Uninstall \(addon.name)?"
        case .forget(let addon): "Remove \(addon.name) from Reload?"
        case .unmanaged(let folder): "Move \(folder.title) to the Trash?"
        }
    }

    var confirmLabel: String {
        switch self {
        case .managed: "Uninstall"
        case .forget: "Remove"
        case .unmanaged: "Move to Trash"
        }
    }

    var message: String {
        switch self {
        case .managed(let addon, let dependents):
            Self.uninstallMessage(addon, dependents: dependents)
        case .forget:
            Self.forgetMessage
        case .unmanaged(let folder):
            Self.trashMessage(folder.folders)
        }
    }

    /// The folders it removes, then the add-ons that stop loading without it.
    static func uninstallMessage(_ addon: InstalledAddon, dependents: [InstalledAddon]) -> String {
        let removes = "Removes \(addon.folders.joined(separator: ", ")) from Interface/AddOns. Saved settings are kept."
        guard let warning = DependencyWording.dependentsSentence(dependents.map(\.name), removing: addon.name) else { return removes }
        return warning + " " + removes
    }

    static let forgetMessage = "Its folders were already deleted. Reload stops tracking it; install it again from Browse any time."

    /// Lists every folder that will move; the Adopt sheet's own dialog uses it too.
    static func trashMessage(_ folders: [String]) -> String {
        let list = folders.joined(separator: ", ")
        let noun = folders.count == 1 ? "folder" : "folders"
        return "Moves \(list) from Interface/AddOns to the Trash. Reload didn't install this \(noun), so it can't reinstall it. Saved settings are kept."
    }
}

/// The Adopt sheet's check of the chosen repository (`UpdateQueue.adoptionPreview`).
enum AdoptionPreviewState: Equatable {
    case loading
    case ready(AdoptionPreview)
    /// No release has a build for the installation's flavor.
    case noBuild
    case failed(String)
}

/// The Adopt sheet's form state, given what's typed and what the preview found. Parsing
/// (`AddonRef(parsing:)`), repo identity (`isSameRepo`) and conflicts (`canAdopt`) are the core's.
enum AdoptForm {
    /// Why the field holds this repo: a candidate's reason, the search, or the user.
    static func reason(for text: String, candidates: [AdoptionCandidate], searched: Set<AddonRef>) -> String? {
        guard let ref = AddonRef(parsing: text) else { return nil }
        if let candidate = candidates.first(where: { $0.ref.isSameRepo(as: ref) }) { return candidate.reason }
        if searched.contains(where: { $0.isSameRepo(as: ref) }) { return "Picked from a GitHub search" }
        return "Entered by hand"
    }

    /// Adopt needs a valid ref; a finished preview of that ref can still rule it out.
    static func canAdopt(text: String, previewed: AddonRef?, preview: AdoptionPreviewState?, isBusy: Bool) -> Bool {
        guard let ref = AddonRef(parsing: text), !isBusy else { return false }
        guard let previewed, previewed.isSameRepo(as: ref), let preview else { return true }
        switch preview {
        case .noBuild: return false
        case .ready(let found): return found.canAdopt
        case .loading, .failed: return true
        }
    }

    /// What to search GitHub for: the typed text unless it's already a ref, else the title.
    static func searchText(field: String, title: String) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || AddonRef(parsing: trimmed) != nil ? title : trimmed
    }
}

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
    case managed(InstalledAddon)
    case unmanaged(UnmanagedFolder)

    var id: String {
        switch self {
        case .managed(let addon): addon.id.description
        case .unmanaged(let folder): AddonStatus.unmanagedID(folder.folder)
        }
    }

    var title: String {
        switch self {
        case .managed(let addon): "Uninstall \(addon.name)?"
        case .unmanaged(let folder): "Move \(folder.title) to the Trash?"
        }
    }

    var confirmLabel: String {
        switch self {
        case .managed: "Uninstall"
        case .unmanaged: "Move to Trash"
        }
    }

    var message: String {
        switch self {
        case .managed(let addon):
            "Removes \(addon.folders.joined(separator: ", ")) from Interface/AddOns. Saved settings are kept."
        case .unmanaged(let folder):
            Self.trashMessage(folder.folders)
        }
    }

    /// Lists every folder that will move; the Adopt sheet's own dialog uses it too.
    static func trashMessage(_ folders: [String]) -> String {
        let list = folders.joined(separator: ", ")
        let noun = folders.count == 1 ? "folder" : "folders"
        return "Moves \(list) from Interface/AddOns to the Trash. ForeverAddons didn't install this \(noun), so it can't reinstall it. Saved settings are kept."
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

/// The Adopt sheet's decisions, given what's typed and what the preview found.
enum AdoptForm {
    /// Accepts `owner/repo`, `github:owner/repo` or a `github.com/owner/repo` URL.
    static func parse(_ text: String) -> AddonRef? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["github:", "https://", "http://", "www.", "github.com/"] where trimmed.lowercased().hasPrefix(prefix) {
            trimmed = String(trimmed.dropFirst(prefix.count))
        }
        if trimmed.hasSuffix(".git") { trimmed = String(trimmed.dropLast(4)) }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts.allSatisfy({ !$0.contains(" ") }) else { return nil }
        return AddonRef(source: .github, identifier: "\(parts[0])/\(parts[1])")
    }

    /// Why the field holds this repo: a candidate's reason, the search, or the user.
    static func reason(for text: String, candidates: [AdoptionCandidate], searched: Set<AddonRef>) -> String? {
        guard let ref = parse(text) else { return nil }
        if let candidate = candidates.first(where: { same($0.ref, ref) }) { return candidate.reason }
        if searched.contains(where: { same($0, ref) }) { return "Picked from a GitHub search" }
        return "Entered by hand"
    }

    /// Adopt needs a valid ref; a finished preview of that ref can still rule it out.
    static func canAdopt(text: String, previewed: AddonRef?, preview: AdoptionPreviewState?, isBusy: Bool) -> Bool {
        guard let ref = parse(text), !isBusy else { return false }
        guard let previewed, same(previewed, ref), let preview else { return true }
        switch preview {
        case .noBuild: return false
        case .ready(let found): return found.conflicts.isEmpty
        case .loading, .failed: return true
        }
    }

    /// What to search GitHub for: the typed text unless it's already a ref, else the title.
    static func searchText(field: String, title: String) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || parse(trimmed) != nil ? title : trimmed
    }

    static func same(_ a: AddonRef, _ b: AddonRef) -> Bool {
        a.source == b.source && a.identifier.caseInsensitiveCompare(b.identifier) == .orderedSame
    }
}

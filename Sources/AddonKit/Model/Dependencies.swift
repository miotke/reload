import Foundation

/// An add-on that can provide a missing dependency (docs/features/dependencies.md).
public struct DependencyCandidate: Sendable, Hashable {
    public var ref: AddonRef
    public var name: String
    /// Why it matches, e.g. "WoWInterface lists the BigWigs folder".
    public var reason: String

    public init(ref: AddonRef, name: String, reason: String) {
        self.ref = ref
        self.name = name
        self.reason = reason
    }
}

/// A folder that a managed add-on's loaded TOC requires (`## Dependencies`, `## RequiredDeps`,
/// `## Dep`) and that isn't in `AddOns/`. The game won't load those add-ons until it is.
/// `Blizzard_*` folders ship with the game and are never missing.
public struct MissingDependency: Sendable, Hashable, Identifiable {
    /// The folder as the TOC names it, e.g. `BigWigs`.
    public var folder: String
    /// Managed add-ons that require it.
    public var requiredBy: [AddonRef]
    /// Add-ons that ship the folder, best first, from sources that are on. Local only.
    public var candidates: [DependencyCandidate]
    /// The one candidate that's certain enough to install without asking; nil when there
    /// are none or several.
    public var suggested: DependencyCandidate?

    public var id: String { folder.lowercased() }

    public init(folder: String, requiredBy: [AddonRef], candidates: [DependencyCandidate] = [], suggested: DependencyCandidate? = nil) {
        self.folder = folder
        self.requiredBy = requiredBy
        self.candidates = candidates
        self.suggested = suggested
    }
}

/// What a front end does when an install leaves dependencies missing (Settings ▸ General,
/// `reload install`).
public enum DependencyPolicy: String, Codable, Sendable, CaseIterable {
    /// Offer to install the suggested add-ons.
    case ask
    /// Install the suggested add-ons without asking.
    case install
    /// Only show the warning.
    case warn
}

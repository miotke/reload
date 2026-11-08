import AddonKit
import Foundation

/// One row of the inspector's Optional Parts section (docs/app/optional-parts.md): the
/// core's `OptionalPart`, worded so the view only reads strings. Which folders are parts, their
/// state and their ref are the core's.
nonisolated struct OptionalPartRow: Identifiable, Hashable, Sendable {
    enum Action: Hashable, Sendable {
        /// Not in AddOns: download it, but only when asked (parts can be over 1 GB).
        case install
        /// In AddOns but not managed: adopt the folder as the part's ref.
        case manage
        case installed
    }

    var part: OptionalPart
    /// The folder, e.g. "SpokenPlacesAudio".
    var name: String
    /// "v2.1.0 · 435 MB · Used by Spoken_Places"; Install already shows the size.
    var detail: String
    /// "435 MB", when the core knows the zip's size.
    var size: String?
    var action: Action
    /// "Install (435 MB)", "Manage…" or "Installed".
    var actionTitle: String
    var actionHelp: String
    /// The `UpdateQueue` row that shows this part's progress and errors: the install's ref,
    /// or the unmanaged folder an adopt works on.
    var rowID: String

    var id: String { part.id }

    init(_ part: OptionalPart) {
        self.part = part
        name = part.folder
        size = part.downloadSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let version = Self.version(part)
        let usedBy = part.usedBy.isEmpty ? nil : "Used by \(DependencyWording.list(part.usedBy))"
        switch part.state {
        case .available:
            action = .install
            actionTitle = size.map { "Install (\($0))" } ?? "Install"
            actionHelp = "Download \(part.folder) \(version) from GitHub"
            detail = [version, usedBy].compactMap(\.self).joined(separator: " · ")
            rowID = part.ref.description
        case .unmanaged:
            action = .manage
            actionTitle = "Manage…"
            actionHelp = "\(part.folder) is in Interface/AddOns, but Reload doesn't update it"
            detail = [version, size, usedBy].compactMap(\.self).joined(separator: " · ")
            rowID = AddonStatus.unmanagedID(part.folder)
        case .installed:
            action = .installed
            actionTitle = "Installed"
            actionHelp = "Reload keeps \(part.folder) up to date"
            detail = [version, size, usedBy].compactMap(\.self).joined(separator: " · ")
            rowID = part.ref.description
        }
    }

    /// "v2.1.0" for the tag "places-audio/v2.1.0": every release of the part has the same
    /// prefix, so it only repeats the name.
    static func version(_ part: OptionalPart) -> String {
        guard let prefix = part.ref.tagPrefix, part.version.hasPrefix(prefix + "/") else { return part.version }
        return String(part.version.dropFirst(prefix.count + 1))
    }

    /// The Manage confirmation: adopting downloads the part's release over the folder.
    var manageMessage: String {
        "Reload downloads \(part.folder) \(Self.version(part))\(size.map { " (\($0))" } ?? "") from GitHub, replaces the folder in Interface/AddOns with it, and keeps it up to date."
    }
}

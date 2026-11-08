import AddonKit
import Foundation

// Wording and follow-ups for required add-ons (docs/app/required-addons.md). Which
// folders are missing, which add-ons provide them and which one is certain enough to
// install are the core's (`MissingDependency`); this only words them and applies the policy
// chosen in Settings ▸ General.

extension DependencyPolicy {
    var title: String {
        switch self {
        case .ask: "Ask to install it"
        case .install: "Install it automatically"
        case .warn: "Only show a warning"
        }
    }

    /// The choice in Settings ▸ General; `.ask` when nothing (or something unknown) is stored.
    static func stored(in defaults: UserDefaults = .standard) -> DependencyPolicy {
        defaults.string(forKey: SettingsKey.dependencyPolicy).flatMap(DependencyPolicy.init(rawValue:)) ?? .ask
    }
}

/// Settings ▸ General's "Warn before removing an add-on others need" (on by default).
enum RemovalWarning {
    static func isOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: SettingsKey.warnBeforeRemovingDependencies) as? Bool ?? true
    }
}

nonisolated enum DependencyWording {
    /// Names shown before "and N others".
    static let listLimit = 3

    /// "A", "A and B", "A, B and C", "A, B, C and 2 others".
    static func list(_ names: [String], limit: Int = listLimit) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        if names.count > limit {
            let rest = names.count - limit
            return names.prefix(limit).joined(separator: ", ") + " and \(rest) \(rest == 1 ? "other" : "others")"
        }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// The Installed table's status: "Needs BigWigs", or "Needs 2 add-ons".
    static func status(_ folders: [String]) -> String? {
        switch folders.count {
        case 0: nil
        case 1: "Needs \(folders[0])"
        default: "Needs \(folders.count) add-ons"
        }
    }

    /// The status's tooltip: what's missing and what it means.
    static func statusHelp(name: String, folders: [String]) -> String? {
        guard !folders.isEmpty else { return nil }
        let verb = folders.count == 1 ? "isn't" : "aren't"
        return "\(list(folders, limit: .max)) \(verb) installed. The game won't load \(name) until \(folders.count == 1 ? "it is" : "they are")."
    }

    /// The removal guard's sentence: "LittleWigs needs BigWigs and will stop loading."
    static func dependentsSentence(_ dependents: [String], removing name: String) -> String? {
        guard !dependents.isEmpty else { return nil }
        let verb = dependents.count == 1 ? "needs" : "need"
        return "\(list(dependents)) \(verb) \(name) and will stop loading."
    }
}

/// What the app does after an install leaves required add-ons missing, given the policy.
/// Only the core's `suggested` candidates are ever installed or offered; folders without one
/// are left to the inspector's Requires section.
nonisolated enum DependencyFollowUp: Equatable {
    case nothing
    case install([DependencyCandidate])
    case ask(DependencyPrompt)

    init(addonName: String, missing: [MissingDependency], policy: DependencyPolicy, installationID: Installation.ID) {
        var candidates: [DependencyCandidate] = []
        var folders: [String] = []
        for dependency in missing {
            guard let suggested = dependency.suggested else { continue }
            folders.append(dependency.folder)
            // One add-on often ships several required folders.
            if !candidates.contains(where: { $0.ref.isSameRepo(as: suggested.ref) }) { candidates.append(suggested) }
        }
        guard !candidates.isEmpty else {
            self = .nothing
            return
        }
        switch policy {
        case .warn: self = .nothing
        case .install: self = .install(candidates)
        case .ask:
            self = .ask(DependencyPrompt(addonName: addonName, folders: folders, candidates: candidates, installationID: installationID))
        }
    }
}

/// The "Install BigWigs too?" confirmation, shown at the window root (`AppModel.pendingDependencies`).
nonisolated struct DependencyPrompt: Equatable, Sendable {
    var addonName: String
    /// The missing folders the candidates provide.
    var folders: [String]
    /// The suggested add-ons, one per repository.
    var candidates: [DependencyCandidate]
    var installationID: Installation.ID

    /// "LittleWigs needs BigWigs"
    var title: String { "\(addonName) needs \(DependencyWording.list(folders, limit: .max))" }
    /// "Install BigWigs too?"
    var message: String { "Install \(DependencyWording.list(candidates.map(\.name), limit: .max)) too?" }
}

// MARK: - Optional parts

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

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

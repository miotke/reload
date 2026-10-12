import AddonKit
import Foundation

/// Picks the installation a command acts on (DESIGN.md §9.3):
/// `--install` flag → config `default-install` → the only Forever install → ask.
enum InstallationSelection {
    enum Outcome: Equatable {
        case selected(Installation)
        /// More than one candidate; ask on a terminal, fail otherwise.
        case ambiguous([Installation])
    }

    /// - Parameters:
    ///   - flag: `--install` value: an installation id, a unique id prefix, or a path.
    ///   - pathLookup: Turns a folder path into an installation (`InstallationLocator.installation(at:)`).
    static func select(
        flag: String?,
        configDefault: String?,
        installations: [Installation],
        pathLookup: (URL) throws -> Installation
    ) throws -> Outcome {
        if let flag, !flag.isEmpty {
            if let match = match(id: flag, in: installations) { return .selected(match) }
            guard looksLikePath(flag) else { throw CLIError.installationNotFound(flag) }
            let url = URL(filePath: (flag as NSString).expandingTildeInPath)
            guard let found = try? pathLookup(url) else { throw CLIError.installationNotFound(flag) }
            return .selected(installations.first { $0.id == found.id } ?? found)
        }
        if let configDefault, let match = installations.first(where: { $0.id == configDefault }) {
            return .selected(match)
        }
        let forever = installations.filter { $0.flavor == .forever }
        switch forever.count {
        case 1: return .selected(forever[0])
        case 0: throw installations.isEmpty ? CLIError.noInstallations : CLIError.noForeverInstallation(installations)
        default: return .ambiguous(forever)
        }
    }

    /// Exact id, else a unique id prefix of at least 4 characters.
    static func match(id: String, in installations: [Installation]) -> Installation? {
        if let exact = installations.first(where: { $0.id == id }) { return exact }
        guard id.count >= 4 else { return nil }
        let prefixed = installations.filter { $0.id.hasPrefix(id) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    static func looksLikePath(_ value: String) -> Bool {
        value.contains("/") || value.hasPrefix("~") || value.hasPrefix(".")
    }
}

/// Decides what a `<ref>` argument means once `AddonManager.lookup` has run.
enum RefSelection {
    enum Outcome: Equatable {
        case single(AddonRef)
        case ambiguous([AddonRef])
        case none
    }

    static func decide(_ candidates: [AddonRef]) -> Outcome {
        var seen = Set<AddonRef>()
        let unique = candidates.filter { seen.insert($0).inserted }
        switch unique.count {
        case 0: return .none
        case 1: return .single(unique[0])
        default: return .ambiguous(unique)
        }
    }
}

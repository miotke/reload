import AddonKit
import Foundation

/// How this launch is wired up: real data, or real data in a separate data folder.
///
/// - `ADDONS_DATA_DIR=<dir>` (environment, same as `addonctl`) keeps the store and caches
///   under `<dir>` and disables installation auto-detection, so nothing real is touched.
/// - Otherwise the real `AddonManager` with the standard Application Support folders.
struct AppEnvironment {
    enum Mode: Equatable {
        case standard
        case dataDirectory(URL)
    }

    var mode: Mode
    var manager: any AddonManaging

    /// Only a normal launch may offer to install the CLI (the offer is remembered in user defaults).
    var offersCommandLineTool: Bool { mode == .standard }

    /// Sandboxed data mustn't record first-launch state (e.g. seeding) in the real defaults.
    var usesStandardDefaults: Bool { mode == .standard }

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppEnvironment {
        if let path = environment["ADDONS_DATA_DIR"]?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            let root = URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            let manager = AddonManager(
                directories: AppDirectories(root: root),
                locator: InstallationLocator(baseFolders: [], findApps: { [] })
            )
            return AppEnvironment(mode: .dataDirectory(root), manager: manager)
        }
        return AppEnvironment(mode: .standard, manager: AddonManager())
    }
}

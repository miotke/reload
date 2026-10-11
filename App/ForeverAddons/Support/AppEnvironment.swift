import AddonKit
import Foundation

/// How this launch is wired up: real data, a sandboxed data folder, or mock data.
///
/// - `-UseMockData YES` (launch argument) runs on `MockAddonManager`.
/// - `ADDONS_DATA_DIR=<dir>` (environment, same as `addonctl`) keeps the store and caches
///   under `<dir>` and disables installation auto-detection, so nothing real is touched.
/// - Otherwise the real `AddonManager` with the standard Application Support folders.
struct AppEnvironment {
    enum Mode: Equatable {
        case standard
        case dataDirectory(URL)
        case mock
    }

    var mode: Mode
    var manager: any AddonManaging

    /// Only a normal launch may offer to install the CLI (the offer is remembered in user defaults).
    var offersCommandLineTool: Bool { mode == .standard }

    static func current(
        arguments: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppEnvironment {
        if arguments.bool(forKey: "UseMockData") {
            return AppEnvironment(mode: .mock, manager: MockAddonManager())
        }
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

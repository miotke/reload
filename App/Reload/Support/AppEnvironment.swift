import AddonKit
import Foundation

/// How this launch is wired up: real data, or real data in a separate data folder.
///
/// - `RELOAD_DATA_DIR=<dir>` (environment, same as `reload`) keeps the store and caches
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
        if let root = dataDirectory(environment) {
            let manager = AddonManager(
                directories: AppDirectories(root: root),
                locator: InstallationLocator(baseFolders: [], findApps: { [] })
            )
            return AppEnvironment(mode: .dataDirectory(root), manager: manager)
        }
        LegacyDataMigration.moveFolders()
        migrateLegacyDefaults()
        return AppEnvironment(mode: .standard, manager: AddonManager())
    }

    /// Settings saved under earlier bundle IDs (decisions 0024, 0026), copied once without
    /// overwriting anything already set. Newest first, so the most recent value wins.
    static func migrateLegacyDefaults(
        into defaults: UserDefaults = .standard,
        from legacy: [[String: Any]] = LegacyDataMigration.legacyBundleIDs.compactMap {
            UserDefaults.standard.persistentDomain(forName: $0)
        }
    ) {
        let marker = "didMigrateLegacyDefaults"
        guard !defaults.bool(forKey: marker) else { return }
        for domain in legacy {
            for (key, value) in domain where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: marker)
    }

    /// The folders this launch's manager uses, for app-side caches such as screenshots.
    nonisolated static func directories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppDirectories {
        dataDirectory(environment).map(AppDirectories.init(root:)) ?? .standard()
    }

    private nonisolated static func dataDirectory(_ environment: [String: String]) -> URL? {
        guard let path = environment["RELOAD_DATA_DIR"]?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }
}

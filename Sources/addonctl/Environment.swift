import AddonKit
import AppKit
import Foundation

/// Process-level settings derived from the environment.
enum CLIEnvironment {
    /// When set, all app data lives under this folder and installations are never
    /// auto-detected: only ones added with `installs add` exist. For development and tests.
    static let dataDirectoryVariable = "ADDONS_DATA_DIR"

    static func dataDirectory(_ environment: [String: String]) -> URL? {
        guard let path = environment[dataDirectoryVariable], !path.isEmpty else { return nil }
        return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    static func directories(_ environment: [String: String]) -> AppDirectories {
        dataDirectory(environment).map { AppDirectories(root: $0) } ?? .standard()
    }

    static func locator(_ environment: [String: String]) -> InstallationLocator {
        dataDirectory(environment) == nil ? InstallationLocator() : InstallationLocator(baseFolders: [], findApps: { [] })
    }
}

/// Whether the game is running, for the "type /reload" notice.
enum WoWProcess {
    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: InstallationLocator.wowBundleID).isEmpty
    }
}

/// Shell-completion candidates for `<ref>` arguments: installed add-on names, read straight
/// from the store files so completion stays fast and never touches the network.
enum RefCompletion {
    private struct StoreFile: Decodable {
        struct Addon: Decodable {
            struct ID: Decodable { var identifier: String }
            var id: ID
            var name: String
        }
        var addons: [Addon]
    }

    @Sendable static func candidates(_ arguments: [String]) -> [String] {
        candidates(directories: CLIEnvironment.directories(ProcessInfo.processInfo.environment))
    }

    static func candidates(directories: AppDirectories) -> [String] {
        let folder = directories.installationsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var names = Set<String>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let store = try? JSONDecoder().decode(StoreFile.self, from: data) else { continue }
            for addon in store.addons {
                if !addon.name.contains(where: \.isWhitespace) { names.insert(addon.name) }
                names.insert(addon.id.identifier)
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

import Foundation
import Testing

/// Table cells, context menus, toolbars and sheets are hosted in their own AppKit views, and
/// reading `@Environment(AppModel.self)` there traps ("No Observable object of type AppModel
/// found") when a table rebuilds its rows. Only scene roots, which apply `.environment(model)`
/// themselves, may read it; everything below gets the model as a property.
@Suite struct EnvironmentUsageTests {
    static let sceneRoots: Set<String> = ["ContentView", "SettingsView", "MenuBarContent"]

    static var appSources: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Reload", directoryHint: .isDirectory)
    }

    @Test func onlySceneRootsReadTheAppModelFromTheEnvironment() throws {
        let files = try #require(FileManager.default.enumerator(at: Self.appSources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)

        let declaration = try Regex(#"^\s*(?:private |fileprivate )?struct (\w+)"#)
        var offenders: [String] = []
        for file in files {
            var currentType: String?
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
                if let match = try declaration.firstMatch(in: String(line)), let name = match.output[1].substring {
                    currentType = String(name)
                }
                if line.contains("@Environment(AppModel.self)"), !Self.sceneRoots.contains(currentType ?? "") {
                    offenders.append("\(file.lastPathComponent): \(currentType ?? "?")")
                }
            }
        }
        #expect(offenders.isEmpty, "Pass the model as a property instead: \(offenders)")
    }
}

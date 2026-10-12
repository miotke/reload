import Foundation
import Testing

/// The app talks to the core only through `AddonManaging` and the public model types
/// (.claude/CLAUDE.md, "UI must not break business logic"). Only `AppEnvironment`, which
/// constructs the manager, may name the concrete type. Comments count too: a comment that
/// names a core internal is usually a sign the code still thinks in terms of it.
@Suite struct ArchitectureTests {
    /// Core internals, and what the app uses instead.
    static let forbidden: [(name: String, instead: String)] = [
        ("AddonManager", "`any AddonManaging` (only AppEnvironment constructs the manager)"),
        ("MetadataDatabase", "`metadataChanges()` and `metadataVersion()` on AddonManaging"),
        ("SupportCache", "`storedAvailability(for:in:)` on AddonManaging"),
        ("InstallStore", "`storeDirectory` and `addons(in:)` on AddonManaging"),
        ("GitHubReleaseResolver", "AddonManaging (`details`, `releaseNotes`, `checkVisible`, `refresh`)"),
        ("SearchCoordinator", "`searchUpdates(_:in:installed:)` on AddonManaging"),
        ("CatalogueSource", "`browse(in:)` and `searchUpdates(_:in:installed:)` on AddonManaging"),
        ("LatestReleaseStore", "`checkForUpdates(in:)` or `refresh(in:force:)` on AddonManaging"),
    ]
    static let allowed: Set<String> = ["AppEnvironment.swift"]

    /// Decisions the core makes, which app code must call rather than re-implement.
    static let reimplemented: [(pattern: String, instead: String)] = [
        (#"\b(enum|struct|class)\s+(InstallAction|UpdateOffer|BrowseFilter)\b"#, "the core's `InstallAction`, `UpdateOffer` and `BrowseFilter`"),
        (#"\.rules\b|\binterfaceRanges\b"#, "the core's flavor decisions (`BrowseFilter`, `InstallAction`, `GameAvailability`), not TOC rules or interface ranges"),
        (#"\bhidesAsIncompatible\b"#, "`BrowseFilter.isHidden(_:for:isInstalled:)`"),
        (#"\bfallbackFlavor\b"#, "`InstallAction.installFallbackBuild` / `Flavor.offeredFallbackBuild(availableFlavors:)`"),
        (#"installedFlavorBuild\s*!=\s*nil\s*&&"#, "`UpdateOffer(installed:update:flavor:)`"),
    ]

    @Test func appSourcesNeverNameCoreInternals() throws {
        let files = try #require(FileManager.default.enumerator(at: EnvironmentUsageTests.appSources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !Self.allowed.contains($0.lastPathComponent) }
        #expect(!files.isEmpty)

        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() {
                for (name, instead) in Self.forbidden where try Regex("\\b\(name)\\b").firstMatch(in: String(line)) != nil {
                    offenders.append("\(file.lastPathComponent):\(number + 1) names \(name); use \(instead)")
                }
            }
        }
        #expect(offenders.isEmpty, "App code must not reach core internals:\n\(offenders.joined(separator: "\n"))")
    }

    @Test func appSourcesDontReimplementCoreDecisions() throws {
        let files = try #require(FileManager.default.enumerator(at: EnvironmentUsageTests.appSources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() {
                for (pattern, instead) in Self.reimplemented where try Regex(pattern).firstMatch(in: String(line)) != nil {
                    offenders.append("\(file.lastPathComponent):\(number + 1): use \(instead)")
                }
            }
        }
        #expect(offenders.isEmpty, "App code re-implements a core decision:\n\(offenders.joined(separator: "\n"))")
    }
}

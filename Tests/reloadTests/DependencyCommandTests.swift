import AddonKit
import Foundation
import Testing
@testable import reload

/// Serves files from disk by URL; anything else fails like a missing download.
struct ServeFiles: DownloadTransport {
    var files: [String: URL]

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let file = files[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
        try FileManager.default.copyItem(at: file, to: destination)
        progress(1)
    }
}

/// Required add-ons in `install`, `remove`, `list` and `doctor` (docs/features/dependencies.md#in-the-cli).
@Suite struct DependencyCommandTests {
    static let bigWigs = AddonRef(source: .github, identifier: "BigWigsMods/BigWigs")
    static let littleWigs = AddonRef(source: .github, identifier: "BigWigsMods/LittleWigs")
    static let bigWigsZip = "https://github.com/BigWigsMods/BigWigs/releases/download/v1/BigWigs-v1.zip"

    /// `AddOns/<folder>` with a Forever TOC requiring `requires`.
    static func addFolder(_ h: CLIHarness, _ folder: String, requires: [String] = []) throws {
        let url = h.installation.addonsDirectory.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let deps = requires.isEmpty ? "" : "## Dependencies: \(requires.joined(separator: ", "))\n"
        try Data("## Interface: 16001\n## Title: \(folder)\n\(deps)".utf8).write(to: url.appending(path: "\(folder).toc"))
    }

    /// A zip of one add-on folder, made with `ditto` so the tests need no zip library.
    static func zip(folder: String) throws -> URL {
        let dir = try temporaryDirectory()
        let source = dir.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("## Interface: 16001\n## Title: \(folder)\n".utf8).write(to: source.appending(path: "\(folder).toc"))
        let zip = dir.appending(path: "\(folder).zip")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", source.path(percentEncoded: false), zip.path(percentEncoded: false)]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return zip
    }

    /// LittleWigs installed and requiring BigWigs; BigWigs in the catalogue and published.
    static func harness(_ arguments: [String]) async throws -> (CLIHarness, InstalledAddon) {
        let h = try await CLIHarness(arguments: arguments, downloads: ServeFiles(files: [bigWigsZip: try zip(folder: "BigWigs")]))
        try addFolder(h, "LittleWigs", requires: ["BigWigs"])
        let littleWigs = makeAddon("BigWigsMods/LittleWigs")
        try await h.install(littleWigs)
        _ = try await h.context.manager.database.execute("""
            INSERT INTO catalogue(full_name, id, name, url, source, first_seen_at, seen_at, changed_at)
            VALUES ('BigWigsMods/BigWigs', '1', 'BigWigs', 'https://github.com/BigWigsMods/BigWigs', 'catalogue', 1, 1, 1)
            """)
        h.http.publishLatest("BigWigsMods/BigWigs", tag: "v1")
        return (h, littleWigs)
    }

    // MARK: - install

    @Test func yesInstallsTheSuggestedDependency() async throws {
        let (h, littleWigs) = try await Self.harness(["--quiet", "--yes"])
        defer { h.cleanUp() }
        var outcome = BatchInstaller.Outcome(installed: [littleWigs])
        let result = try await DependencyOffer.run(after: &outcome, noDeps: false, force: false, context: h.context, installation: h.installation)
        #expect(result.attempted == 1)
        #expect(result.missing.isEmpty)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.installed.map(\.id) == [Self.littleWigs, Self.bigWigs])
        #expect(FileManager.default.fileExists(atPath: h.installation.addonsDirectory.appending(path: "BigWigs/BigWigs.toc").path(percentEncoded: false)))
    }

    @Test func noDepsOnlyWarns() async throws {
        let (h, littleWigs) = try await Self.harness(["--quiet", "--yes"])
        defer { h.cleanUp() }
        var outcome = BatchInstaller.Outcome(installed: [littleWigs])
        let result = try await DependencyOffer.run(after: &outcome, noDeps: true, force: false, context: h.context, installation: h.installation)
        #expect(result.attempted == 0)
        #expect(result.missing.map(\.folder) == ["BigWigs"])
        #expect(result.missing.first?.suggested?.ref == Self.bigWigs)
        #expect(outcome.installed.count == 1)
    }

    @Test func withoutATerminalOrYesItOnlyWarns() async throws {
        let (h, littleWigs) = try await Self.harness(["--quiet"])
        defer { h.cleanUp() }
        var outcome = BatchInstaller.Outcome(installed: [littleWigs])
        let result = try await DependencyOffer.run(after: &outcome, noDeps: false, force: false, context: h.context, installation: h.installation)
        #expect(result.attempted == 0)
        #expect(result.missing.map(\.folder) == ["BigWigs"])
    }

    @Test func jsonReportsMissingDependenciesInsteadOfAsking() async throws {
        let (h, littleWigs) = try await Self.harness(["--json"])
        defer { h.cleanUp() }
        var outcome = BatchInstaller.Outcome(installed: [littleWigs])
        let result = try await DependencyOffer.run(after: &outcome, noDeps: false, force: false, context: h.context, installation: h.installation)
        #expect(result.attempted == 0)

        let output = InstallOutput(installation: h.installation.id, installed: outcome.installed, failed: [],
                                   missingDependencies: result.missing.map(MissingDependencyJSON.init))
        let json = try JSONSerialization.jsonObject(with: Data(JSONOutput.document(output).utf8)) as? [String: Any]
        let missing = try #require(json?["missingDependencies"] as? [[String: Any]])
        #expect(missing.first?["folder"] as? String == "BigWigs")
        #expect((missing.first?["suggested"] as? [String: Any])?["reason"] as? String == "Named BigWigs in the catalogue")
        #expect((missing.first?["requiredBy"] as? [Any])?.count == 1)
    }

    @Test func wording() {
        let names = [Self.littleWigs: "LittleWigs", ref("o/Capping"): "Capping"]
        let candidate = DependencyCandidate(ref: Self.bigWigs, name: "BigWigs", reason: "Named BigWigs in the catalogue")
        var dependency = MissingDependency(folder: "BigWigs", requiredBy: [Self.littleWigs], candidates: [candidate], suggested: candidate)
        #expect(DependencyOffer.question(dependency, candidate: candidate, names: names)
                == "LittleWigs needs BigWigs. Install BigWigs (BigWigsMods/BigWigs)?")
        #expect(DependencyOffer.warning(dependency, names: names)
                == "LittleWigs needs BigWigs, which isn't installed; install it with `reload install BigWigsMods/BigWigs`.")

        dependency.requiredBy.append(ref("o/Capping"))
        dependency.suggested = nil
        dependency.candidates.append(DependencyCandidate(ref: AddonRef(source: .wowinterface, identifier: "5086"), name: "BigWigs", reason: "WoWInterface lists the BigWigs folder"))
        #expect(DependencyOffer.warning(dependency, names: names) == """
            LittleWigs and Capping need BigWigs, which isn't installed. It may come from BigWigsMods/BigWigs (Named BigWigs in the catalogue), \
            wowinterface:5086 (WoWInterface lists the BigWigs folder).
            """)

        dependency.candidates = []
        #expect(DependencyOffer.warning(dependency, names: names)
                == "LittleWigs and Capping need BigWigs, which isn't installed. Search for it with `reload search BigWigs`.")
    }

    // MARK: - remove

    @Test func removeSaysWhatStopsLoading() async throws {
        let (h, _) = try await Self.harness(["--quiet"])
        defer { h.cleanUp() }
        try Self.addFolder(h, "BigWigs")
        let bigWigs = makeAddon("BigWigsMods/BigWigs")
        try await h.install(bigWigs)

        let dependents = await h.context.manager.dependents(of: Self.bigWigs, in: h.installation)
        #expect(dependents.map(\.name) == ["LittleWigs"])
        let warnings = DependencyOffer.removalWarnings([(bigWigs, dependents)])
        #expect(RemoveCommand.question([bigWigs], warnings: warnings)
                == "Remove BigWigs (1 folder)? Folders go to the Trash. LittleWigs needs BigWigs and will stop loading.")
        #expect(RemoveCommand.question([bigWigs], warnings: []) == "Remove BigWigs (1 folder)? Folders go to the Trash.")
        let two = [makeAddon("o/A"), makeAddon("o/B")]
        #expect(DependencyOffer.removalWarnings([(bigWigs, two), (two[0], [])]) == ["A and B need BigWigs and will stop loading."])
    }

    // MARK: - list and doctor

    @Test func listShowsWhatAnAddonNeeds() async throws {
        let (h, littleWigs) = try await Self.harness(["--quiet"])
        defer { h.cleanUp() }
        let needs = ListCommand.needs(await h.context.manager.missingDependencies(in: h.installation))
        #expect(needs == [Self.littleWigs: ["BigWigs"]])

        let statuses: [AddonStatus] = [.managed(littleWigs, missingFolders: [])]
        #expect(Format.listTable(statuses, flavor: .forever, needs: needs, style: .plain).contains("stable   needs BigWigs"))
        #expect(AddonStatusJSON(statuses[0], missingDependencies: needs[Self.littleWigs]).missingDependencies == ["BigWigs"])
        #expect(AddonStatusJSON(statuses[0]).missingDependencies == [])
    }

    @Test func doctorWarnsAboutMissingDependencies() async throws {
        let (h, _) = try await Self.harness(["--quiet"])
        defer { h.cleanUp() }
        let missing = await h.context.manager.missingDependencies(in: h.installation)
        let checks = DoctorCommand.dependencies(missing, names: [Self.littleWigs: "LittleWigs"], label: "x")
        #expect(checks == [DoctorCommand.Check(
            name: "x", level: .warning,
            message: "LittleWigs needs BigWigs, which isn't installed; install it with `reload install BigWigsMods/BigWigs`.")])
    }
}

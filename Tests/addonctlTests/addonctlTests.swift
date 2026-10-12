import AddonKit
import ArgumentParser
import Foundation
import Testing
@testable import addonctl

// MARK: - Fixtures

func makeInstallation(_ id: String, flavor: Flavor = .forever, path: String? = nil) -> Installation {
    Installation(id: id, root: URL(filePath: path ?? "/tmp/wow-\(id)/_classic_beta_"), flavor: flavor)
}

func makeAddon(_ identifier: String, name: String? = nil, version: String = "v1", pinned: Bool = false, channel: Channel = .stable, folders: [String]? = nil) -> InstalledAddon {
    let repo = String(identifier.split(separator: "/").last!)
    return InstalledAddon(
        id: AddonRef(source: .github, identifier: identifier), name: name ?? repo, folders: folders ?? [repo],
        version: version, releaseID: 1, assetName: "\(repo).zip",
        publishedAt: Date(timeIntervalSince1970: 1_700_000_000), installedAt: Date(timeIntervalSince1970: 1_700_000_100),
        channel: channel, pinned: pinned
    )
}

func ref(_ identifier: String) -> AddonRef { AddonRef(source: .github, identifier: identifier) }

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "addonctlTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func jsonObject(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

// MARK: - Installation selection

@Suite struct InstallationSelectionTests {
    let a = makeInstallation("aaaa1111")
    let b = makeInstallation("bbbb2222")
    let retail = makeInstallation("cccc3333", flavor: .mainline)
    let noPaths: (URL) throws -> Installation = { _ in throw AddonError.installationNotFound("x") }

    @Test func flagMatchesIdOrUniquePrefix() throws {
        #expect(try InstallationSelection.select(flag: "bbbb2222", configDefault: nil, installations: [a, b], pathLookup: noPaths) == .selected(b))
        #expect(try InstallationSelection.select(flag: "aaaa", configDefault: "bbbb2222", installations: [a, b], pathLookup: noPaths) == .selected(a))
    }

    @Test func shortOrUnknownFlagIsAnError() {
        #expect(throws: CLIError.installationNotFound("aa")) {
            try InstallationSelection.select(flag: "aa", configDefault: nil, installations: [a, b], pathLookup: noPaths)
        }
        #expect(throws: CLIError.installationNotFound("nope")) {
            try InstallationSelection.select(flag: "nope", configDefault: nil, installations: [a], pathLookup: noPaths)
        }
    }

    @Test func flagPathPrefersStoredInstallation() throws {
        let stored = makeInstallation("dddd4444", path: "/stored/_classic_beta_")
        let lookup: (URL) throws -> Installation = { url in
            #expect(url.path == "/some/World of Warcraft/_classic_beta_")
            return makeInstallation("dddd4444", path: "/fresh/_classic_beta_")
        }
        let outcome = try InstallationSelection.select(flag: "/some/World of Warcraft/_classic_beta_", configDefault: nil, installations: [a, stored], pathLookup: lookup)
        #expect(outcome == .selected(stored))
    }

    @Test func configDefaultThenOnlyInstall() throws {
        #expect(try InstallationSelection.select(flag: nil, configDefault: "bbbb2222", installations: [a, b], pathLookup: noPaths) == .selected(b))
        // A stale default falls through to the only install, whatever its flavor.
        #expect(try InstallationSelection.select(flag: nil, configDefault: "gone", installations: [a], pathLookup: noPaths) == .selected(a))
        #expect(try InstallationSelection.select(flag: nil, configDefault: "gone", installations: [retail], pathLookup: noPaths) == .selected(retail))
        let mists = makeInstallation("eeee5555", flavor: .mists)
        #expect(try InstallationSelection.select(flag: nil, configDefault: nil, installations: [mists], pathLookup: noPaths) == .selected(mists))
    }

    @Test func severalInstallsAreAmbiguous() throws {
        #expect(try InstallationSelection.select(flag: nil, configDefault: nil, installations: [a, b, retail], pathLookup: noPaths) == .ambiguous([a, b, retail]))
        #expect(try InstallationSelection.select(flag: nil, configDefault: "gone", installations: [a, retail], pathLookup: noPaths) == .ambiguous([a, retail]))
    }

    @Test func noInstallations() {
        #expect(throws: CLIError.noInstallations) {
            try InstallationSelection.select(flag: nil, configDefault: nil, installations: [], pathLookup: noPaths)
        }
    }

    @Test func effectiveDefaultIsTheOnlyInstallOfAnyFlavor() {
        #expect(InstallsCommand.List.effectiveDefault(installations: [retail], configured: nil) == retail.id)
        #expect(InstallsCommand.List.effectiveDefault(installations: [a, retail], configured: nil) == nil)
        #expect(InstallsCommand.List.effectiveDefault(installations: [a, retail], configured: retail.id) == retail.id)
    }

    @Test func installsTableAndDoctorShowDisplayNames() {
        let mists = makeInstallation("eeee5555", flavor: .mists)
        let table = Format.installsTable([a, mists], defaultID: nil, style: .plain)
        #expect(table.contains("Forever"))
        #expect(table.contains("Mists Classic"))
        #expect(DoctorCommand.flavorCounts([a, b, mists]) == "2 Forever, 1 Mists Classic")
    }
}

// MARK: - Ref selection

@Suite struct RefSelectionTests {
    @Test func outcomes() {
        #expect(RefSelection.decide([]) == .none)
        #expect(RefSelection.decide([ref("a/b"), ref("a/b")]) == .single(ref("a/b")))
        #expect(RefSelection.decide([ref("a/b"), ref("c/d"), ref("a/b")]) == .ambiguous([ref("a/b"), ref("c/d")]))
    }

    @Test func ambiguousErrorListsCandidatesWithUsageExit() {
        let error = CLIError.ambiguousReference("dbm", [ref("A/DBM"), ref("B/DBM")])
        #expect(ExitStatus.code(for: error) == 2)
        #expect(ExitStatus.message(for: error).contains("A/DBM"))
        #expect(ExitStatus.message(for: error).contains("B/DBM"))
    }
}

// MARK: - Formatting

@Suite struct FormattingTests {
    @Test func tableAlignsColumnsAndTrimsTrailingSpace() {
        let table = Table(headers: ["NAME", "VERSION", ""], rows: [["BigWigs", "v426.4", ""], ["DBM", "12.1.12", "(installed)"]])
        #expect(table.render(style: .plain) == """
              NAME     VERSION
              BigWigs  v426.4
              DBM      12.1.12  (installed)
            """)
    }

    @Test func tableIgnoresANSIWhenMeasuring() {
        let style = Style(enabled: true)
        let table = Table(headers: [], rows: [[style.green("ok"), "x"], ["long one", "y"]])
        let lines = table.render(style: style).split(separator: "\n").map { Style.strip(String($0)) }
        #expect(lines == ["  ok        x", "  long one  y"])
    }

    @Test func relativeDates() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(Format.relative(nil, now: now) == "—")
        #expect(Format.relative(now.addingTimeInterval(-30), now: now) == "just now")
        #expect(Format.relative(now.addingTimeInterval(-3600), now: now) == "1 hour ago")
        #expect(Format.relative(now.addingTimeInterval(-2 * 86_400), now: now) == "2 days ago")
        #expect(Format.relative(now.addingTimeInterval(-8 * 86_400), now: now) == "1 week ago")
        #expect(Format.relative(now.addingTimeInterval(-400 * 86_400), now: now) == "1 year ago")
    }

    @Test func searchTable() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let results = [
            SearchResult(id: ref("BigWigsMods/BigWigs"), name: "BigWigs", owner: "BigWigsMods", lastUpdated: now.addingTimeInterval(-2 * 86_400),
                         installed: makeAddon("BigWigsMods/BigWigs"), support: .supported(version: "v426.4"), origin: [.catalogue]),
            SearchResult(id: ref("BigWigsMods/LittleWigs"), name: "LittleWigs", owner: "BigWigsMods", lastUpdated: now.addingTimeInterval(-8 * 86_400),
                         support: .unknown, origin: [.catalogue]),
        ]
        #expect(Format.searchTable(results, flavor: .forever, style: .plain, now: now) == """
              NAME        REPO                    FOREVER    UPDATED
              BigWigs     BigWigsMods/BigWigs     ✓ v426.4   2 days ago  (installed)
              LittleWigs  BigWigsMods/LittleWigs  ? unknown  1 week ago
            """)
    }

    @Test func listTableShowsPinsMissingAndUnmanaged() {
        let statuses: [AddonStatus] = [
            .managed(makeAddon("a/Alpha", pinned: true), missingFolders: []),
            .managed(makeAddon("b/Beta"), missingFolders: ["Beta"]),
            .unmanaged(folder: "Gamma", toc: Toc(fields: ["version": "3"]), suggestedRef: ref("g/Gamma")),
        ]
        let text = Format.listTable(statuses, style: .plain)
        #expect(text.contains("Alpha  v1       a/Alpha     stable   pinned"))
        #expect(text.contains("missing: Beta"))
        #expect(text.contains("Gamma  3        → g/Gamma?  —        unmanaged"))
    }

    @Test func listFilter() {
        let statuses: [AddonStatus] = [
            .managed(makeAddon("a/Alpha"), missingFolders: []),
            .managed(makeAddon("b/Beta"), missingFolders: ["Beta"]),
            .unmanaged(folder: "Gamma", toc: nil, suggestedRef: nil),
        ]
        #expect(ListCommand.filter(statuses, unmanaged: false, missing: false).count == 2)
        #expect(ListCommand.filter(statuses, unmanaged: true, missing: false).count == 3)
        #expect(ListCommand.filter(statuses, unmanaged: true, missing: true).map(\.id) == ["github:b/Beta"])
    }

    @Test func searchFilterHidesUnsupportedUnlessAll() {
        let results = [SupportStatus.supported(version: "1"), .unsupported, .unknown, .noReleases].enumerated().map {
            SearchResult(id: ref("o/r\($0.offset)"), name: "r\($0.offset)", owner: "o", support: $0.element, origin: [.catalogue])
        }
        #expect(SearchCommand.filter(results, all: false, limit: 10).map(\.name) == ["r0", "r2"])
        #expect(SearchCommand.filter(results, all: true, limit: 3).map(\.name) == ["r0", "r1", "r2"])
    }

    @Test func progressBarWithoutColourUsesDistinctGlyphs() {
        #expect(ProgressBoard.bar(0.5, width: 4, style: .plain) == "━━──")
    }

    @Test func doctorIntegrityFindsSharedFolders() {
        let statuses: [AddonStatus] = [
            .managed(makeAddon("a/One", folders: ["Shared", "One"]), missingFolders: ["One"]),
            .managed(makeAddon("b/Two", folders: ["shared"]), missingFolders: []),
        ]
        let checks = DoctorCommand.integrity(statuses, label: "x")
        #expect(checks.first?.level == .ok)
        #expect(checks.contains { $0.level == .warning && $0.message.contains("One is missing One") })
        #expect(checks.contains { $0.level == .error && $0.message == "shared is claimed by One and Two" })
    }
}

// MARK: - Colour

@Suite struct ColourTests {
    @Test func colourOnlyOnATerminal() {
        #expect(Style.colorEnabled(isTTY: true, noColorFlag: false, json: false, environment: [:]))
        #expect(!Style.colorEnabled(isTTY: false, noColorFlag: false, json: false, environment: [:]))
        #expect(!Style.colorEnabled(isTTY: true, noColorFlag: true, json: false, environment: [:]))
        #expect(!Style.colorEnabled(isTTY: true, noColorFlag: false, json: true, environment: [:]))
        #expect(!Style.colorEnabled(isTTY: true, noColorFlag: false, json: false, environment: ["NO_COLOR": "1"]))
        #expect(!Style.colorEnabled(isTTY: true, noColorFlag: false, json: false, environment: ["TERM": "dumb"]))
        // An empty NO_COLOR doesn't count (no-color.org).
        #expect(Style.colorEnabled(isTTY: true, noColorFlag: false, json: false, environment: ["NO_COLOR": ""]))
    }

    @Test func disabledStyleIsPlain() {
        #expect(Style.plain.red("x") == "x")
        #expect(Style(enabled: true).red("x") == "\u{1B}[31mx\u{1B}[0m")
        #expect(Style.strip(Style(enabled: true).bold("hi")) == "hi")
        #expect(Format.support(.supported(version: "v1"), style: .plain) == "✓ v1")
    }

    @Test func contextHonoursNoColorAndPipes() throws {
        var options = try GlobalOptions.parse([])
        let tty = Console(stdinIsTTY: true, stdoutIsTTY: true, stderrIsTTY: true)
        let dataDir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let env = ["ADDONS_DATA_DIR": dataDir.path, "ADDONS_GITHUB_TOKEN": "t"]

        #expect(CLIContext(options: options, environment: env, console: tty).style.enabled)
        #expect(!CLIContext(options: options, environment: env.merging(["NO_COLOR": "1"]) { $1 }, console: tty).style.enabled)
        let piped = CLIContext(options: options, environment: env, console: Console(stdinIsTTY: false, stdoutIsTTY: false, stderrIsTTY: false))
        #expect(!piped.style.enabled)
        #expect(!piped.interactive)
        #expect(!piped.showsProgress)
        options.json = true
        #expect(!CLIContext(options: options, environment: env, console: tty).interactive)
    }

    @Test func dataDirectoryIsolatesStorage() throws {
        let root = URL(filePath: "/tmp/addons-iso")
        let directories = CLIEnvironment.directories(["ADDONS_DATA_DIR": root.path])
        #expect(directories == AppDirectories(root: root))
        #expect(CLIEnvironment.directories([:]) == .standard())
    }
}

// MARK: - JSON

@Suite struct JSONTests {
    @Test func documentHasSchemaVersionAndISODates() throws {
        struct Payload: Encodable { var addons: [InstalledAddon] }
        let text = try JSONOutput.document(Payload(addons: [makeAddon("BigWigsMods/BigWigs")]))
        let object = try jsonObject(text)
        #expect(object["schemaVersion"] as? Int == 1)
        let addon = try #require((object["addons"] as? [[String: Any]])?.first)
        #expect(addon["publishedAt"] as? String == "2023-11-14T22:13:20Z")
        let id = try #require(addon["id"] as? [String: String])
        #expect(id == ["source": "github", "identifier": "BigWigsMods/BigWigs"])
    }

    @Test func supportAndUpdateStateShapes() throws {
        let release = ResolvedRelease(ref: ref("o/r"), name: "R", version: "v2", releaseID: 2, publishedAt: Date(timeIntervalSince1970: 0),
                                      downloadURL: URL(string: "https://example.com/r.zip")!, assetName: "r.zip", changelog: "notes", reasoning: ["why"])
        struct Payload: Encodable { var support: [SupportJSON]; var states: [UpdateStateJSON] }
        let text = try JSONOutput.document(Payload(
            support: [SupportJSON(.supported(version: "v1")), SupportJSON(.needsDownload)],
            states: [UpdateStateJSON(.available(release)), UpdateStateJSON(.failed("boom")), UpdateStateJSON(.pinned)]
        ))
        let object = try jsonObject(text)
        let support = try #require(object["support"] as? [[String: String]])
        #expect(support == [["status": "supported", "version": "v1"], ["status": "needsDownload"]])
        let states = try #require(object["states"] as? [[String: Any]])
        #expect(states.map { $0["state"] as? String } == ["available", "failed", "pinned"])
        let available = try #require(states[0]["release"] as? [String: Any])
        #expect(available["version"] as? String == "v2")
        #expect(available["publishedAt"] as? String == "1970-01-01T00:00:00Z")
        #expect(available["reasoning"] as? [String] == ["why"])
        #expect(available["changelog"] == nil)  // left out of update states
        #expect(states[1]["message"] as? String == "boom")
    }

    @Test func addonStatusShapes() throws {
        struct Payload: Encodable { var addons: [AddonStatusJSON] }
        let text = try JSONOutput.document(Payload(addons: [
            AddonStatusJSON(.managed(makeAddon("a/A"), missingFolders: ["A"])),
            AddonStatusJSON(.unmanaged(folder: "F", toc: Toc(fields: ["title": "Eff", "version": "9"]), suggestedRef: ref("f/F"))),
        ]))
        let addons = try #require(try jsonObject(text)["addons"] as? [[String: Any]])
        #expect(addons[0]["kind"] as? String == "managed")
        #expect(addons[0]["missingFolders"] as? [String] == ["A"])
        #expect(addons[1]["kind"] as? String == "unmanaged")
        #expect(addons[1]["title"] as? String == "Eff")
        #expect((addons[1]["suggestedRef"] as? [String: String])?["identifier"] == "f/F")
    }

    @Test func errorDocument() throws {
        let object = try jsonObject(JSONOutput.error(AddonError.unmanagedFolderExists("BigWigs")))
        let error = try #require(object["error"] as? [String: String])
        #expect(error["code"] == "unmanaged_folder")
        #expect(error["message"]?.contains("--force") == true)
    }
}

// MARK: - Exit codes

@Suite struct ExitCodeTests {
    static let cases: [(any Error, Int32)] = [
        (AddonError.rateLimited(resetAt: nil), 4),
        (AddonError.unmanagedFolderExists("X"), 5),
        (AddonError.folderConflict(folder: "X", owner: AddonRef(source: .github, identifier: "o/r")), 5),
        (AddonError.invalidReference("??"), 2),
        (AddonError.notFound(AddonRef(source: .github, identifier: "o/r")), 1),
        (AddonError.noCompatibleRelease(AddonRef(source: .github, identifier: "o/r"), .forever), 1),
        (CLIError.usage("x"), 2),
        (CLIError.confirmationRequired("remove"), 2),
        (CLIError.ambiguousInstallation([]), 2),
        (CLIError.referenceNotFound("x"), 1),
        (CLIError.partialFailure(failed: 1, total: 2), 3),
        (CLIError.allFailed(count: 2, exitCode: 5), 5),
        (ExitCode(10), 10),
        (ValidationError("bad"), 2),
        (URLError(.notConnectedToInternet), 1),
    ]

    @Test(arguments: cases)
    func mapping(error: any Error, code: Int32) {
        #expect(ExitStatus.code(for: error) == code)
    }

    @Test func batchErrors() {
        let conflict = AddonError.unmanagedFolderExists("X")
        let limited = AddonError.rateLimited(resetAt: nil)
        #expect(ExitStatus.batchError(failures: [], total: 3) == nil)
        // One item that failed keeps its own error and code.
        #expect(ExitStatus.batchError(failures: [conflict], total: 1).map(ExitStatus.code(for:)) == 5)
        // Everything failed for the same reason: keep the code.
        #expect(ExitStatus.batchError(failures: [limited, limited], total: 2).map(ExitStatus.code(for:)) == 4)
        // Some succeeded, or mixed reasons: partial failure.
        #expect(ExitStatus.batchError(failures: [conflict], total: 2).map(ExitStatus.code(for:)) == 3)
        #expect(ExitStatus.batchError(failures: [conflict, limited], total: 2).map(ExitStatus.code(for:)) == 3)
    }

    @Test func operationFailureRecoversRateLimit() {
        let message = AddonError.rateLimited(resetAt: nil).localizedDescription
        #expect(ExitStatus.code(for: OperationFailure(message: message).typed()) == 4)
        #expect(ExitStatus.code(for: OperationFailure(message: "HTTP 500").typed()) == 1)
        // The stored rate-limit state decides even when the message doesn't say so.
        let now = Date(timeIntervalSince1970: 1_000)
        let exhausted = RateLimitState(remaining: 0, resetAt: now.addingTimeInterval(600))
        #expect(ExitStatus.code(for: OperationFailure(message: "HTTP 403").typed(rateLimit: exhausted, now: now)) == 4)
        let reset = RateLimitState(remaining: 0, resetAt: now.addingTimeInterval(-1))
        #expect(ExitStatus.code(for: OperationFailure(message: "HTTP 403").typed(rateLimit: reset, now: now)) == 1)
    }

    @Test func tagsMatch() {
        #expect(BatchInstaller.tagsMatch("v426.4", "426.4"))
        #expect(BatchInstaller.tagsMatch("V1", "v1"))
        #expect(!BatchInstaller.tagsMatch("v426.3", "v426.4"))
    }
}

// MARK: - Export / import

@Suite struct AddonsFileTests {
    @Test func roundTrip() throws {
        let installed = [
            makeAddon("BigWigsMods/BigWigs", version: "v426.4", pinned: true),
            makeAddon("DeadlyBossMods/DeadlyBossMods", name: "DBM", version: "12.1", channel: .prerelease),
        ]
        let file = AddonsFile(installed: installed, exportedAt: Date(timeIntervalSince1970: 0))
        let data = try file.encoded()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["exportedAt"] as? String == "1970-01-01T00:00:00Z")

        let decoded = try AddonsFile.decode(data)
        #expect(decoded == file)
        #expect(decoded.addons.map(\.ref) == ["github:BigWigsMods/BigWigs", "github:DeadlyBossMods/DeadlyBossMods"])
        #expect(decoded.addons[0].version == "v426.4")  // pinned: version kept
        #expect(decoded.addons[1].version == nil)       // unpinned: latest on import
        #expect(decoded.addons[1].channel == .prerelease)

        // Importing into an installation that already has BigWigs installs only DBM.
        let plan = try ImportCommand.plan(decoded, installed: [installed[0]])
        #expect(plan.existing.map(\.addon.id) == [installed[0].id])
        #expect(plan.requests.map(\.ref) == [installed[1].id])
        #expect(plan.requests[0].channel == .prerelease)
        #expect(!plan.requests[0].strictVersion)

        let fresh = try ImportCommand.plan(decoded, installed: [])
        #expect(fresh.requests[0].version == "v426.4")
        #expect(fresh.requests[0].pin)
    }

    @Test func rejectsBadFiles() {
        #expect(throws: CLIError.self) { try AddonsFile.decode(Data("{}".utf8)) }
        #expect(throws: CLIError.self) { try AddonsFile.decode(Data(#"{"schemaVersion": 99, "addons": []}"#.utf8)) }
        let badRef = AddonsFile(addons: [.init(ref: "not a ref", channel: .stable, pinned: false)])
        #expect(throws: AddonError.invalidReference("not a ref")) { try ImportCommand.plan(badRef, installed: []) }
    }
}

// MARK: - Config & completion

@Suite(.serialized) struct ConfigTests {
    @Test func storeRoundTripAndService() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigStore(directories: AppDirectories(root: root))
        #expect(store.load() == CLIConfig())

        let keychain = KeychainStore(service: "com.andrewmiotke.ForeverAddons.addonctlTests.\(UUID().uuidString)")
        defer { try? keychain.delete() }
        let service = ConfigService(store: store, keychain: keychain, environment: [:])

        try service.set(.defaultChannel, to: "Prerelease")
        try service.set(.defaultInstall, to: "abcd1234")
        #expect(store.load() == CLIConfig(defaultChannel: .prerelease, defaultInstall: "abcd1234"))
        #expect(service.get(.defaultChannel) == "prerelease")
        #expect(throws: CLIError.self) { try service.set(.defaultChannel, to: "nightly") }
        try service.unset(.defaultInstall)
        #expect(service.get(.defaultInstall) == nil)

        #expect(service.get(.githubToken) == nil)
        try service.set(.githubToken, to: "ghp_abcdefghijklmnop\n")
        #expect(keychain.get() == "ghp_abcdefghijklmnop")
        #expect(service.get(.githubToken) == "ghp_…mnop (from Keychain)")
        try service.unset(.githubToken)
        #expect(keychain.get() == nil)

        let fromEnv = ConfigService(store: store, keychain: keychain, environment: ["GITHUB_TOKEN": "abcdefghijkl"])
        #expect(fromEnv.get(.githubToken) == "abcd…ijkl (from $GITHUB_TOKEN)")
    }

    @Test func completionListsInstalledNames() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AppDirectories(root: root)
        let store = InstallStore(directories: directories)
        let installation = makeInstallation("comp1234")
        try await store.save(installation)
        try await store.upsert(makeAddon("BigWigsMods/BigWigs"), in: installation)
        try await store.upsert(makeAddon("DeadlyBossMods/DeadlyBossMods", name: "Deadly Boss Mods"), in: installation)

        #expect(RefCompletion.candidates(directories: directories) == [
            "BigWigs", "BigWigsMods/BigWigs", "DeadlyBossMods/DeadlyBossMods",
        ])
    }
}

// MARK: - Argument parsing

@Suite struct ParsingTests {
    @Test func aliasesAndGlobalOptions() throws {
        let command = try AddonCtl.parseAsRoot(["rm", "bigwigs", "-y", "--json", "-I", "abcd"])
        let remove = try #require(command as? RemoveCommand)
        #expect(remove.refs == ["bigwigs"])
        #expect(remove.global.yes && remove.global.json)
        #expect(remove.global.install == "abcd")

        #expect(try AddonCtl.parseAsRoot(["up", "--dry-run"]) is UpdateCommand)
        #expect(try AddonCtl.parseAsRoot(["i", "o/r", "--version", "v1"]) is InstallCommand)
        #expect(try AddonCtl.parseAsRoot(["s", "boss", "--limit", "5"]) is SearchCommand)
        #expect(try AddonCtl.parseAsRoot(["show", "x"]) is InfoCommand)
        #expect(try AddonCtl.parseAsRoot(["ls", "--unmanaged"]) is ListCommand)
        #expect(try AddonCtl.parseAsRoot(["installs"]) is InstallsCommand.List)
        #expect(try AddonCtl.parseAsRoot(["config", "set", "default-channel", "stable"]) is ConfigCommand.SetValue)
        #expect((try AddonCtl.parseAsRoot(["refresh", "--force"]) as? RefreshCommand)?.force == true)
        #expect((try AddonCtl.parseAsRoot(["cache", "clear", "--metadata"]) as? CacheCommand.Clear)?.metadata == true)
        #expect((try AddonCtl.parseAsRoot(["cache", "clear"]) as? CacheCommand.Clear)?.metadata == false)
    }

    @Test func usageErrors() {
        #expect(throws: (any Error).self) { try AddonCtl.parseAsRoot(["channel", "x", "nightly"]) }
        #expect(throws: (any Error).self) { try AddonCtl.parseAsRoot(["config", "set", "github-token", "secret"]) }
        #expect(throws: (any Error).self) { try AddonCtl.parseAsRoot(["adopt", "OnlyFolder"]) }
    }

    @Test func tokenMask() {
        #expect(ConfigService.mask("short") == "••••")
        #expect(ConfigService.mask("github_pat_1234567890abcd") == "gith…abcd")
    }
}

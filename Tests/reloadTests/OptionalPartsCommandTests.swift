import AddonKit
import Foundation
import Testing
@testable import reload

/// Optional parts in `install --with-optional` and `info` (docs/features/optional-parts.md).
@Suite struct OptionalPartsCommandTests {
    static let main = AddonRef(source: .github, identifier: "rk/voices")
    static let pack = AddonRef(source: .github, identifier: "rk/voices", tagPrefix: "pack")
    static let packZip = "https://downloads.test/rk/voices/VoicesPack-2.zip"

    /// `rk/voices` installed at `voices/v1`, its TOC listing `VoicesPack` in `OptionalDeps`,
    /// and the repo publishing `VoicesPack-2.zip` under `pack/v2`.
    static func harness(_ arguments: [String]) async throws -> (CLIHarness, InstalledAddon) {
        let h = try await CLIHarness(arguments: arguments, downloads: ServeFiles(files: [packZip: try DependencyCommandTests.zip(folder: "VoicesPack")]))
        let folder = h.installation.addonsDirectory.appending(path: "Voices", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("## Interface: 16001\n## Title: Voices\n## OptionalDeps: VoicesPack, Missing\n".utf8).write(to: folder.appending(path: "Voices.toc"))
        let voices = makeAddon("rk/voices", version: "voices/v1", folders: ["Voices"])
        try await h.install(voices)
        h.http.stub("https://github.com/rk/voices/releases/latest", status: 302, headers: ["Location": "https://github.com/rk/voices/releases/tag/voices/v1"])
        h.http.stub("https://api.github.com/repos/rk/voices/releases?per_page=100", headers: ["ETag": #""1""#], body: """
            [{"id": 2, "tag_name": "pack/v2", "draft": false, "prerelease": false, "published_at": "2026-10-02T00:00:00Z",
              "assets": [{"id": 20, "name": "VoicesPack-2.zip", "state": "uploaded", "size": 456000000, "browser_download_url": "\(packZip)"}]},
             {"id": 1, "tag_name": "voices/v1", "draft": false, "prerelease": false, "published_at": "2026-10-01T00:00:00Z",
              "assets": [{"id": 10, "name": "Voices-1.zip", "state": "uploaded", "size": 1000, "browser_download_url": "https://downloads.test/v1.zip"}]}]
            """)
        return (h, voices)
    }

    @Test func yesInstallsEachAvailablePart() async throws {
        let (h, voices) = try await Self.harness(["--quiet", "--yes"])
        defer { h.cleanUp() }
        var outcome = BatchInstaller.Outcome(installed: [voices])
        let result = try await OptionalPartsOffer.run(after: &outcome, force: false, context: h.context, installation: h.installation)
        #expect(result.attempted == 1)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.installed.map(\.id) == [Self.main, Self.pack])
        #expect(result.parts.map(\.state) == [.installed])
        #expect(FileManager.default.fileExists(atPath: h.installation.addonsDirectory.appending(path: "VoicesPack/VoicesPack.toc").path(percentEncoded: false)))
    }

    @Test func withoutATerminalOrYesItOnlyLists() async throws {
        let (h, voices) = try await Self.harness(["--quiet"])
        defer { h.cleanUp() }
        var outcome = BatchInstaller.Outcome(installed: [voices])
        let result = try await OptionalPartsOffer.run(after: &outcome, force: false, context: h.context, installation: h.installation)
        #expect(result.attempted == 0)
        #expect(result.parts.map(\.ref) == [Self.pack])
        #expect(result.parts.first?.state == .available)
        #expect(outcome.installed.count == 1)
    }

    @Test func jsonIncludesTheParts() async throws {
        let (h, voices) = try await Self.harness(["--json"])
        defer { h.cleanUp() }
        let parts = await OptionalPartsOffer.gather([voices.id], context: h.context, installation: h.installation)
        let output = InstallOutput(installation: h.installation.id, installed: [voices], failed: [], optionalParts: parts.map(OptionalPartJSON.init))
        let json = try JSONSerialization.jsonObject(with: Data(JSONOutput.document(output).utf8)) as? [String: Any]
        let first = try #require((json?["optionalParts"] as? [[String: Any]])?.first)
        #expect(first["folder"] as? String == "VoicesPack")
        #expect(first["state"] as? String == "available")
        #expect(first["downloadSize"] as? Int == 456_000_000)
        #expect((first["ref"] as? [String: Any])?["tagPrefix"] as? String == "pack")

        let plain = InstallOutput(installation: h.installation.id, installed: [voices], failed: [])
        let without = try JSONSerialization.jsonObject(with: Data(JSONOutput.document(plain).utf8)) as? [String: Any]
        #expect(without?["optionalParts"] == nil, "only with --with-optional")
    }

    @Test func wording() {
        let part = OptionalPart(ref: Self.pack, folder: "VoicesPack", usedBy: ["Voices", "Voices_Zones"], version: "pack/v2", downloadSize: 456_000_000, state: .available)
        #expect(OptionalPartsOffer.describe(part) == "VoicesPack (pack/v2, \(Format.bytes(456_000_000)), for Voices and Voices_Zones)")
        #expect(OptionalPartsOffer.stateName(.unmanaged) == "not managed")
    }

    @Test func refsWithAPrefixParse() async throws {
        let (h, _) = try await Self.harness(["--quiet"])
        defer { h.cleanUp() }
        #expect(try await h.context.ref(for: "rk/voices#pack", in: h.installation) == Self.pack)
        #expect(try await h.context.ref(for: "github:rk/voices#pack", in: h.installation) == Self.pack)
        let command = try InstallCommand.parse(["rk/voices", "--with-optional"])
        #expect(command.withOptional)
        #expect(command.refs == ["rk/voices"])
    }
}

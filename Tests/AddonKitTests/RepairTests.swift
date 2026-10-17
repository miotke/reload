import Foundation
import Testing
@testable import AddonKit

/// Add-ons whose folders were deleted outside Reload (docs/features/installing.md#repair).
@Suite struct RepairTests {
    static let ref = AddonRef(source: .github, identifier: "Owner/Addon")

    func installThenDelete(_ h: ManagerHarness) async throws -> URL {
        try h.publish("Owner/Addon", [("v1", 1, 1)])
        try await h.manager.install(Self.ref, into: h.installation)
        let folder = h.installation.addonsDirectory.appending(path: "Addon", directoryHint: .isDirectory)
        try FileManager.default.removeItem(at: folder)
        // A newer release is out; repair still puts back what was installed.
        try h.publish("Owner/Addon", [("v2", 2, 2), ("v1", 1, 1)])
        return folder
    }

    @Test func repairPutsBackTheSameReleaseFromTheCacheWithoutTheNetwork() async throws {
        let h = try await ManagerHarness()
        let folder = try await installThenDelete(h)
        try await h.manager.setPinned(true, for: Self.ref, in: h.installation)
        h.http.reset()
        let downloads = h.transport.requests.count

        let repaired = try await h.manager.repair(Self.ref, in: h.installation, progress: { _ in })
        #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        #expect(repaired.version == "v1")
        #expect(repaired.pinned, "repair keeps the pin")
        #expect(h.http.requests.isEmpty)
        #expect(h.transport.requests.count == downloads)
    }

    @Test func withoutTheCachedDownloadItInstallsWhatTheChannelOffers() async throws {
        let h = try await ManagerHarness()
        let folder = try await installThenDelete(h)
        try FileManager.default.removeItem(at: h.directories.downloadsDirectory)

        let repaired = try await h.manager.repair(Self.ref, in: h.installation, progress: { _ in })
        #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        #expect(repaired.version == "v2")
    }

    @Test func removingAnAddonWhoseFilesAreGoneForgetsIt() async throws {
        let h = try await ManagerHarness()
        _ = try await installThenDelete(h)
        try await h.manager.uninstall(Self.ref, from: h.installation)
        #expect(try await h.manager.addons(in: h.installation).isEmpty)
    }

    @Test func repairingSomethingNotInstalledFails() async throws {
        let h = try await ManagerHarness()
        await #expect(throws: AddonError.self) {
            _ = try await h.manager.repair(Self.ref, in: h.installation, progress: { _ in })
        }
    }
}

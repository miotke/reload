import Foundation
import Synchronization
import Testing
@testable import AddonKit

/// Every file under `dir`, keyed by relative path, for byte-for-byte comparisons.
func snapshot(_ dir: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    let root = dir.resolvingSymlinksInPath().path(percentEncoded: false)
    guard let enumerator = FileManager.default.enumerator(at: dir.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey]) else { return [:] }
    for case let url as URL in enumerator {
        let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        let relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            result[relative + "/"] = Data()
        } else {
            result[relative] = try Data(contentsOf: url)
        }
    }
    return result
}

struct InstallerFixture {
    let tmp: URL
    let installation: Installation
    let ref = AddonRef(source: .github, identifier: "Owner/Addon")
    let otherRef = AddonRef(source: .github, identifier: "Someone/Else")

    init() throws {
        tmp = try makeTempDirectory()
        let root = tmp.appending(path: "World of Warcraft/_classic_beta_", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        installation = Installation(id: "test", root: root, flavor: .forever)
    }

    var addons: URL { installation.addonsDirectory }

    func release(_ id: Int64, ref: AddonRef? = nil) -> ResolvedRelease {
        ResolvedRelease(
            ref: ref ?? self.ref, name: "Addon", version: "v\(id)", releaseID: id,
            publishedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + id)),
            downloadURL: URL(string: "https://example.com/\(id).zip")!, assetName: "Addon-v\(id).zip"
        )
    }

    func zip(_ folders: [String], marker: String) throws -> URL {
        try makeAddonZip(folders: folders, marker: marker, named: "\(marker).zip", in: tmp)
    }

    func lua(_ folder: String) throws -> String {
        try String(contentsOf: addons.appending(path: "\(folder)/Core.lua"), encoding: .utf8)
    }

    func exists(_ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: addons.appending(path: folder).path(percentEncoded: false))
    }

    func makeFolder(_ folder: String, contents: String = "unmanaged") throws {
        let dir = addons.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: dir.appending(path: "Core.lua"))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: tmp) }

    /// Entries in the parent of `AddOns/` (to spot leftover staging folders).
    func interfaceListing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: addons.deletingLastPathComponent().path(percentEncoded: false)).sorted()
    }
}

@Suite struct InstallerTests {
    @Test func freshInstallCreatesAddOnsFolder() throws {
        let f = try InstallerFixture()
        defer { f.cleanUp() }
        let installed = try Installer().install(
            archive: f.zip(["Addon", "Addon_Options"], marker: "v1"), into: f.installation,
            release: f.release(1), current: [], force: false, now: Date(timeIntervalSince1970: 5)
        )
        #expect(installed.id == f.ref)
        #expect(installed.folders == ["Addon", "Addon_Options"])
        #expect(installed.releaseID == 1)
        #expect(installed.version == "v1")
        #expect(installed.assetName == "Addon-v1.zip")
        #expect(installed.installedAt == Date(timeIntervalSince1970: 5))
        #expect(try f.lua("Addon") == "-- Addon v1\n")
        #expect(try f.lua("Addon_Options") == "-- Addon_Options v1\n")
        #expect(try f.interfaceListing() == ["AddOns"])
    }

    @Test func updateReplacesAndDropsFoldersAndKeepsSettings() throws {
        let f = try InstallerFixture()
        defer { f.cleanUp() }
        let installer = Installer()
        var v1 = try installer.install(archive: f.zip(["Addon", "Addon_Old"], marker: "v1"), into: f.installation,
                                       release: f.release(1), current: [], force: false)
        v1.pinned = true
        v1.channel = .prerelease
        v1.etag = "\"abc\""
        let other = try installer.install(archive: f.zip(["Other"], marker: "o1"), into: f.installation,
                                          release: f.release(9, ref: f.otherRef), current: [v1], force: false)

        let v2 = try installer.install(archive: f.zip(["Addon", "Addon_New"], marker: "v2"), into: f.installation,
                                       release: f.release(2), current: [v1, other], force: false)
        #expect(v2.folders == ["Addon", "Addon_New"])
        #expect(v2.pinned && v2.channel == .prerelease && v2.etag == "\"abc\"")
        #expect(try f.lua("Addon") == "-- Addon v2\n")
        #expect(f.exists("Addon_New"))
        #expect(!f.exists("Addon_Old"))
        #expect(try f.lua("Other") == "-- Other o1\n")
    }

    @Test func folderConflictWithAnotherManagedAddon() throws {
        let f = try InstallerFixture()
        defer { f.cleanUp() }
        let installer = Installer()
        let other = try installer.install(archive: f.zip(["Shared"], marker: "o1"), into: f.installation,
                                          release: f.release(9, ref: f.otherRef), current: [], force: false)
        #expect(throws: AddonError.folderConflict(folder: "Shared", owner: f.otherRef)) {
            try installer.install(archive: f.zip(["Addon", "Shared"], marker: "v1"), into: f.installation,
                                  release: f.release(1), current: [other], force: true)
        }
        #expect(!f.exists("Addon"))
        #expect(try f.lua("Shared") == "-- Shared o1\n")
    }

    @Test func unmanagedFolderNeedsForce() throws {
        let f = try InstallerFixture()
        defer { f.cleanUp() }
        try f.makeFolder("Addon")
        let installer = Installer()
        #expect(throws: AddonError.unmanagedFolderExists("Addon")) {
            try installer.install(archive: f.zip(["Addon"], marker: "v1"), into: f.installation,
                                  release: f.release(1), current: [], force: false)
        }
        #expect(try f.lua("Addon") == "unmanaged")

        _ = try installer.install(archive: f.zip(["Addon"], marker: "v1"), into: f.installation,
                                  release: f.release(1), current: [], force: true)
        #expect(try f.lua("Addon") == "-- Addon v1\n")
    }

    @Test func rejectsBlizzardFoldersAndUnsafeArchives() throws {
        let f = try InstallerFixture()
        defer { f.cleanUp() }
        try f.makeFolder("Blizzard_Thing", contents: "blizz")
        let installer = Installer()
        #expect(throws: AddonError.self) {
            try installer.install(archive: f.zip(["Blizzard_Thing"], marker: "v1"), into: f.installation,
                                  release: f.release(1), current: [], force: true)
        }
        #expect(try f.lua("Blizzard_Thing") == "blizz")

        let evil = try makeTestZip([.file("Addon/Addon.toc", "## Interface: 16001"), .file("../../evil.lua", "x")], named: "evil.zip", in: f.tmp)
        #expect(throws: AddonError.unsafeArchivePath("../../evil.lua")) {
            try installer.install(archive: evil, into: f.installation, release: f.release(1), current: [], force: true)
        }
        #expect(!f.exists("Addon"))
    }

    @Test(arguments: [
        Installer.SwapStep.backup("Addon"),
        .moveIn("Addon"),
        .moveIn("Addon_B"),
        .backup("Addon_Old"),
    ])
    func failureMidSwapRestoresOriginals(failAt: Installer.SwapStep) throws {
        let f = try InstallerFixture()
        defer { f.cleanUp() }
        var installer = Installer()
        let v1 = try installer.install(archive: f.zip(["Addon", "Addon_B", "Addon_Old"], marker: "v1"), into: f.installation,
                                       release: f.release(1), current: [], force: false)
        try Data("saved".utf8).write(to: f.addons.appending(path: "Addon/local.txt"))
        try f.makeFolder("Unrelated")
        let before = try snapshot(f.addons)
        let listingBefore = try f.interfaceListing()

        struct Boom: Error {}
        installer.faultInjection = { step in if step == failAt { throw Boom() } }
        #expect(throws: Boom.self) {
            try installer.install(archive: f.zip(["Addon", "Addon_B"], marker: "v2"), into: f.installation,
                                  release: f.release(2), current: [v1], force: false)
        }
        #expect(try snapshot(f.addons) == before)
        #expect(try f.interfaceListing() == listingBefore)
    }

    @Test func siblingStagingFallbackIsCleanedUp() throws {
        let f = try InstallerFixture()
        defer { f.cleanUp() }
        var installer = Installer()
        installer.forceSiblingStaging = true
        _ = try installer.install(archive: f.zip(["Addon"], marker: "v1"), into: f.installation,
                                  release: f.release(1), current: [], force: false)
        #expect(try f.lua("Addon") == "-- Addon v1\n")
        #expect(try f.interfaceListing() == ["AddOns"])

        struct Boom: Error {}
        installer.faultInjection = { _ in throw Boom() }
        #expect(throws: Boom.self) {
            try installer.install(archive: f.zip(["Addon"], marker: "v2"), into: f.installation,
                                  release: f.release(2), current: [], force: true)
        }
        #expect(try f.interfaceListing() == ["AddOns"])
        #expect(try f.lua("Addon") == "-- Addon v1\n")
    }

    /// Extraction happens before the store lock, so the ownership check runs after it; a
    /// failed check must still leave nothing behind.
    @Test func aFailedOwnershipCheckAfterExtractionDeletesTheStaging() throws {
        let f = try InstallerFixture()
        defer { f.cleanUp() }
        var installer = Installer()
        installer.forceSiblingStaging = true
        let other = try installer.install(archive: f.zip(["Shared"], marker: "o1"), into: f.installation,
                                          release: f.release(1, ref: f.otherRef), current: [], force: false)
        let before = try snapshot(f.addons)

        let prepared = try installer.prepare(archive: f.zip(["Addon", "Shared"], marker: "v1"), into: f.installation)
        #expect(prepared.folders == ["Addon", "Shared"])
        #expect(try f.interfaceListing().count == 2, "staged next to AddOns, nothing moved in yet")
        #expect(try snapshot(f.addons) == before)
        #expect(throws: AddonError.folderConflict(folder: "Shared", owner: f.otherRef)) {
            try installer.commit(prepared, release: f.release(2), current: [other], force: false)
        }
        #expect(try f.interfaceListing() == ["AddOns"])
        #expect(try snapshot(f.addons) == before)
    }

    @Test func aPreparedInstallThatIsNeverCommittedCanBeDiscarded() throws {
        let f = try InstallerFixture()
        defer { f.cleanUp() }
        var installer = Installer()
        installer.forceSiblingStaging = true
        let prepared = try installer.prepare(archive: f.zip(["Addon"], marker: "v1"), into: f.installation)
        prepared.discard()
        #expect(try f.interfaceListing() == ["AddOns"])
        #expect(!f.exists("Addon"))
    }

    @Test func uninstallTrashesOwnedFoldersOnly() throws {
        let f = try InstallerFixture()
        defer { f.cleanUp() }
        let trashed = LockedBox<[String]>([])
        let installer = Installer(trash: { url in
            trashed.withValue { $0.append(url.lastPathComponent) }
            try FileManager.default.removeItem(at: url)
        })
        try f.makeFolder("Addon")
        try f.makeFolder("Blizzard_UI")
        try f.makeFolder("Unrelated")
        let addon = InstalledAddon(
            id: f.ref, name: "Addon", folders: ["Addon", "Addon_Missing", "Blizzard_UI", "../Unrelated"],
            version: "v1", releaseID: 1, assetName: "a.zip", publishedAt: .now, installedAt: .now
        )
        try installer.uninstall(addon, from: f.installation)
        #expect(trashed.value == ["Addon"])
        #expect(!f.exists("Addon"))
        #expect(f.exists("Blizzard_UI"))
        #expect(f.exists("Unrelated"))
    }
}

/// A tiny thread-safe box for collecting values from `@Sendable` closures.
final class LockedBox<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    var value: Value { mutex.withLock { $0 } }
    func withValue<R: Sendable>(_ body: (inout sending Value) throws -> sending R) rethrows -> R {
        try mutex.withLock { try body(&$0) }
    }
}

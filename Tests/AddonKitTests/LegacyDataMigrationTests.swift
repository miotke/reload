import Foundation
import Testing
@testable import AddonKit

/// Moving folders from earlier bundle IDs to the current one (decisions 0024, 0026), on temp folders only.
@Suite struct LegacyDataMigrationTests {
    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "LegacyDataMigrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func movesLegacyFoldersOnce() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = AppDirectories(root: root.appending(path: "old"))
        let current = AppDirectories(root: root.appending(path: "new"))
        try FileManager.default.createDirectory(at: legacy.installationsDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.applicationSupport.appending(path: "config.json"))
        try FileManager.default.createDirectory(at: legacy.downloadsDirectory, withIntermediateDirectories: true)

        #expect(LegacyDataMigration.moveFolders(to: current, from: [legacy]).count == 2)
        #expect(FileManager.default.fileExists(atPath: current.applicationSupport.appending(path: "config.json").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: current.downloadsDirectory.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: legacy.applicationSupport.path(percentEncoded: false)))
        #expect(LegacyDataMigration.moveFolders(to: current, from: [legacy]).isEmpty, "nothing left to move")
    }

    @Test func neverReplacesExistingFolders() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = AppDirectories(root: root.appending(path: "old"))
        let current = AppDirectories(root: root.appending(path: "new"))
        for dir in [legacy.applicationSupport, current.applicationSupport] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        #expect(LegacyDataMigration.moveFolders(to: current, from: [legacy]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: legacy.applicationSupport.path(percentEncoded: false)))
    }

    @Test func newestLegacyFolderWins() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let newer = AppDirectories(root: root.appending(path: "newer"))
        let older = AppDirectories(root: root.appending(path: "older"))
        let current = AppDirectories(root: root.appending(path: "new"))
        for (dirs, name) in [(newer, "newer.json"), (older, "older.json")] {
            try FileManager.default.createDirectory(at: dirs.applicationSupport, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dirs.applicationSupport.appending(path: name))
        }

        #expect(LegacyDataMigration.moveFolders(to: current, from: [newer, older]).count == 1)
        #expect(FileManager.default.fileExists(atPath: current.applicationSupport.appending(path: "newer.json").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: older.applicationSupport.path(percentEncoded: false)), "older data is left alone")
    }
}

import Foundation
import Testing
import ZIPFoundation
@testable import AddonKit

/// One entry in a test zip.
enum TestZipEntry {
    case file(String, String)
    case directory(String)
    case symlink(String, target: String)
}

/// Builds a zip at `dir/name` from `entries`. Paths are written verbatim, so tests can
/// create hostile archives (`../x`, absolute paths, symlinks).
@discardableResult
func makeTestZip(_ entries: [TestZipEntry], named name: String = "test.zip", in dir: URL) throws -> URL {
    let url = dir.appending(path: name)
    try? FileManager.default.removeItem(at: url)
    let archive = try Archive(url: url, accessMode: .create)
    for entry in entries {
        switch entry {
        case .file(let path, let contents):
            let data = Data(contents.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        case .directory(let path):
            try archive.addEntry(with: path.hasSuffix("/") ? path : path + "/", type: .directory, uncompressedSize: Int64(0)) { (_: Int64, _: Int) in Data() }
        case .symlink(let path, let target):
            let data = Data(target.utf8)
            try archive.addEntry(with: path, type: .symlink, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }
    return url
}

/// A minimal valid add-on zip: each folder gets `<F>/<F>.toc` and `<F>/Core.lua` containing `marker`.
@discardableResult
func makeAddonZip(folders: [String], marker: String = "v1", named name: String = "addon.zip", in dir: URL) throws -> URL {
    var entries: [TestZipEntry] = []
    for folder in folders {
        entries.append(.directory(folder))
        entries.append(.file("\(folder)/\(folder).toc", "## Interface: 16001\n## Title: \(folder)\n## Version: \(marker)\nCore.lua\n"))
        entries.append(.file("\(folder)/Core.lua", "-- \(folder) \(marker)\n"))
    }
    return try makeTestZip(entries, named: name, in: dir)
}

@Suite struct ZipExtractorTests {
    @Test func extractsValidArchive() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let zip = try makeTestZip([
            .file("BigWigs/BigWigs.toc", "## Interface: 16001"),
            .file("BigWigs/Modules/Core.lua", "print(1)"),
            .directory("BigWigs_Core"),
            .file("BigWigs_Core/BigWigs_Core_Camelot.toc", "## Interface: 16001"),
            .file("__MACOSX/BigWigs/._BigWigs.toc", "junk"),
            .file(".DS_Store", "junk"),
            .file("BigWigs/.DS_Store", "junk"),
        ], in: tmp)

        #expect(try ZipExtractor.topLevelFolders(in: zip) == ["BigWigs", "BigWigs_Core"])

        let dest = tmp.appending(path: "out")
        let folders = try ZipExtractor.extract(zip, to: dest)
        #expect(folders == ["BigWigs", "BigWigs_Core"])
        let lua = try String(contentsOf: dest.appending(path: "BigWigs/Modules/Core.lua"), encoding: .utf8)
        #expect(lua == "print(1)")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dest.appending(path: "BigWigs_Core/BigWigs_Core_Camelot.toc").path))
        #expect(!fm.fileExists(atPath: dest.appending(path: "__MACOSX").path))
        #expect(!fm.fileExists(atPath: dest.appending(path: ".DS_Store").path))
        #expect(!fm.fileExists(atPath: dest.appending(path: "BigWigs/.DS_Store").path))
    }

    @Test func folderWithoutTocIsAllowedIfAnotherHasOne() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let zip = try makeTestZip([
            .file("A/A.toc", "## Interface: 16001"),
            .file("Libs/LibStub.lua", ""),
        ], in: tmp)
        #expect(try ZipExtractor.topLevelFolders(in: zip) == ["A", "Libs"])
    }

    @Test(arguments: [
        "../evil.lua",
        "A/../../evil.lua",
        "/etc/evil",
        "A\\..\\..\\evil.lua",
        "C:/evil.lua",
    ])
    func rejectsUnsafePaths(path: String) throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let zip = try makeTestZip([.file("A/A.toc", "## Interface: 16001"), .file(path, "x")], in: tmp)
        #expect(throws: AddonError.unsafeArchivePath(path)) { try ZipExtractor.topLevelFolders(in: zip) }
        let dest = tmp.appending(path: "out")
        #expect(throws: AddonError.unsafeArchivePath(path)) { try ZipExtractor.extract(zip, to: dest) }
        #expect(!FileManager.default.fileExists(atPath: tmp.appending(path: "evil.lua").path))
        #expect(!FileManager.default.fileExists(atPath: dest.appending(path: "A").path), "nothing extracted before validation")
    }

    @Test func rejectsSymlinks() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let zip = try makeTestZip([
            .file("A/A.toc", "## Interface: 16001"),
            .symlink("A/link", target: "/etc"),
        ], in: tmp)
        #expect(throws: AddonError.unsafeArchivePath("A/link")) { try ZipExtractor.topLevelFolders(in: zip) }
    }

    @Test func rejectsStrayTopLevelFiles() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let zip = try makeTestZip([.file("A/A.toc", "## Interface: 16001"), .file("README.md", "hi")], in: tmp)
        #expect(throws: AddonError.invalidArchive("stray top-level file README.md")) { try ZipExtractor.topLevelFolders(in: zip) }
    }

    @Test func rejectsArchiveWithoutToc() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A GitHub-style source zipball: the .toc is one level too deep.
        let zip = try makeTestZip([.file("BigWigs-v1/BigWigs/BigWigs.toc", "## Interface: 16001")], in: tmp)
        #expect(throws: AddonError.invalidArchive("no top-level folder contains a .toc file")) { try ZipExtractor.topLevelFolders(in: zip) }
    }

    @Test func rejectsEmptyAndNonZip() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let empty = try makeTestZip([.file("__MACOSX/x", "")], named: "empty.zip", in: tmp)
        #expect(throws: AddonError.invalidArchive("archive is empty")) { try ZipExtractor.topLevelFolders(in: empty) }

        let bogus = tmp.appending(path: "bogus.zip")
        try Data("not a zip".utf8).write(to: bogus)
        #expect(throws: AddonError.self) { try ZipExtractor.topLevelFolders(in: bogus) }
    }

    @Test func extractsFixtureMadeByMacOSArchiver() throws {
        // Created with `ditto -c -k --sequesterRsrc`, so it carries __MACOSX/ and .DS_Store noise.
        let zip = fixtureURL("install/MacArchived.zip")
        #expect(try ZipExtractor.topLevelFolders(in: zip) == ["MacAddon"])
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try ZipExtractor.extract(zip, to: tmp)
        #expect(FileManager.default.fileExists(atPath: tmp.appending(path: "MacAddon/MacAddon.toc").path))
    }
}

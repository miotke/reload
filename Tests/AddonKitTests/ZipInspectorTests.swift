import Foundation
import Testing
import ZIPFoundation
@testable import AddonKit

/// Writes a zip with the given `path → contents` entries to a fresh temp dir and returns its URL.
func makeInspectorZip(_ files: [String: String], name: String = "test.zip") throws -> URL {
    let url = try makeTempDirectory().appending(path: name)
    let archive = try Archive(url: url, accessMode: .create)
    for (path, text) in files.sorted(by: { $0.key < $1.key }) {
        let data = Data(text.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
    return url
}

@Suite struct ZipInspectorTests {
    @Test func foreverSuffixMatches() throws {
        let zip = try makeInspectorZip([
            "BigWigs/BigWigs.toc": "## Interface: 120100",
            "BigWigs/BigWigs_Camelot.toc": "## Interface: 16001",
            "BigWigs/Core.lua": "",
            "BigWigs_Core/BigWigs_Core.toc": "## Interface: 120100",
        ])
        let result = try ZipInspector.inspect(zipAt: zip, flavor: .forever)
        #expect(result.isSupported)
        #expect(result.matchedToc == "BigWigs/BigWigs_Camelot.toc")
        #expect(result.addonFolders == ["BigWigs", "BigWigs_Core"])
    }

    @Test func dashForeverSuffixMatchesWithoutReadingInterface() throws {
        let zip = try makeInspectorZip(["DBM-Core/DBM-Core-Forever.toc": "## Interface: 1", "DBM-Core/DBM-Core.toc": "## Interface: 120100"])
        let result = try ZipInspector.inspect(zipAt: zip, flavor: .forever)
        #expect(result.isSupported)
        #expect(result.matchedToc == "DBM-Core/DBM-Core-Forever.toc")
    }

    @Test func mainlineTocWithForeverInterface() throws {
        let zip = try makeInspectorZip([
            "Plater/Plater_Mainline.toc": "## Interface: 120100, 16001\n## Title: Plater",
            "Plater/Plater.toc": "## Interface: 11508",
        ])
        let result = try ZipInspector.inspect(zipAt: zip, flavor: .forever)
        #expect(result.isSupported)
        #expect(result.matchedToc == "Plater/Plater_Mainline.toc")
        #expect(result.detail.contains("16001"))
    }

    @Test func mainlineTocWinsOverBase() throws {
        // The client loads `_Mainline` before the base TOC, so a Forever interface only in the base doesn't count.
        let zip = try makeInspectorZip([
            "A/A_Mainline.toc": "## Interface: 120100",
            "A/A.toc": "## Interface: 16001",
        ])
        #expect(try !ZipInspector.supports(.forever, zipAt: zip))
    }

    @Test func baseTocOnly() throws {
        let zip = try makeInspectorZip(["Leatrix_Plus/Leatrix_Plus.toc": "\u{FEFF}## Interface: 16001\r\n"])
        let result = try ZipInspector.inspect(zipAt: zip, flavor: .forever)
        #expect(result.isSupported)
        #expect(result.matchedToc == "Leatrix_Plus/Leatrix_Plus.toc")
    }

    @Test func retailOnlyRejected() throws {
        let zip = try makeInspectorZip([
            "Details/Details.toc": "## Interface: 120100",
            "Details/Details_Classic.toc": "## Interface: 11508",
        ])
        let result = try ZipInspector.inspect(zipAt: zip, flavor: .forever)
        #expect(!result.isSupported)
        #expect(result.matchedToc == nil)
        #expect(result.detail.contains("120100"))
    }

    @Test func macOSXFolderAndNestedTocsIgnored() throws {
        let zip = try makeInspectorZip([
            "__MACOSX/__MACOSX.toc": "## Interface: 16001",
            "__MACOSX/A/._A_Camelot.toc": "junk",
            "A/._A_Camelot.toc": "junk",
            "A/A.toc": "## Interface: 120100",
            "A/Libs/Lib/Lib_Camelot.toc": "## Interface: 16001",
            "Wrapper/A/A_Camelot.toc": "## Interface: 16001",
            "B/A_Camelot.toc": "## Interface: 16001",
        ])
        let result = try ZipInspector.inspect(zipAt: zip, flavor: .forever)
        #expect(!result.isSupported)
        #expect(result.addonFolders == ["A"])
    }

    @Test func noAddonFolders() throws {
        let zip = try makeInspectorZip(["README.md": "hi"])
        let result = try ZipInspector.inspect(zipAt: zip, flavor: .forever)
        #expect(!result.isSupported)
        #expect(result.addonFolders.isEmpty)
    }

    @Test func invalidZipThrows() throws {
        let url = try makeTempDirectory().appending(path: "bad.zip")
        try Data("not a zip".utf8).write(to: url)
        #expect(throws: AddonError.self) { try ZipInspector.inspect(zipAt: url, flavor: .forever) }
    }

    @Test func addonFolderOnDisk() throws {
        let addons = try makeTempDirectory()
        let folder = addons.appending(path: "Plater", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("## Interface: 120100, 16001".utf8).write(to: folder.appending(path: "Plater_Mainline.toc"))
        try Data("## Interface: 11508".utf8).write(to: folder.appending(path: "Plater.toc"))
        let result = try ZipInspector.inspect(addonFolder: folder, flavor: .forever)
        #expect(result.isSupported)
        #expect(result.matchedToc == "Plater/Plater_Mainline.toc")
        #expect(!ZipInspector.supports(.mainline, addonFolder: addons.appending(path: "Missing")))

        let retail = addons.appending(path: "Retail", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: retail, withIntermediateDirectories: true)
        try Data("## Interface: 120100".utf8).write(to: retail.appending(path: "Retail.toc"))
        #expect(!ZipInspector.supports(.forever, addonFolder: retail))
        #expect(ZipInspector.supports(.mainline, addonFolder: retail))
    }
}

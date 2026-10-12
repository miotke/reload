import Foundation
import Testing
@testable import AddonKit

@Suite struct CSVParserTests {
    @Test func plainRows() {
        #expect(CSVParser.parse("a,b,c\n1,2,3\n") == [["a", "b", "c"], ["1", "2", "3"]])
    }

    @Test func noTrailingNewline() {
        #expect(CSVParser.parse("a,b\n1,2") == [["a", "b"], ["1", "2"]])
    }

    @Test func quotedFieldsWithCommasQuotesAndNewlines() {
        let text = "a,b,c\n\"x, y\",\"say \"\"hi\"\"\",\"line1\nline2\"\n"
        #expect(CSVParser.parse(text) == [["a", "b", "c"], ["x, y", "say \"hi\"", "line1\nline2"]])
    }

    @Test func crlfLineEndings() {
        #expect(CSVParser.parse("a,b\r\n1,\"2\r\n3\"\r\n") == [["a", "b"], ["1", "2\r\n3"]])
    }

    @Test func emptyFieldsAndBlankLines() {
        #expect(CSVParser.parse("a,,c\n\n,,\n") == [["a", "", "c"], ["", "", ""]])
    }

    @Test func emptyQuotedField() {
        #expect(CSVParser.parse("\"\",x\n") == [["", "x"]])
    }

    @Test func byteOrderMarkIsStripped() {
        #expect(CSVParser.parse("\u{FEFF}id,name\n1,x\n") == [["id", "name"], ["1", "x"]])
    }

    @Test func strayQuotesAreLenient() {
        #expect(CSVParser.parse("ab\"c,d\n") == [["ab\"c", "d"]])
        #expect(CSVParser.parse("\"ab\"c,d\n") == [["abc", "d"]])
    }

    @Test func unicodeIsPreserved() {
        #expect(CSVParser.parse("Ätherwind,\"日本語, ok\"\n") == [["Ätherwind", "日本語, ok"]])
    }
}

@Suite struct CatalogueCSVTests {
    static let header = "id,name,full_name,url,description,last_updated,flavors,curse_id,wago_id,wowi_id,has_release_json,last_seen\n"

    @Test func mapsAllColumns() throws {
        let csv = Self.header + #"""
        900000011,BossWarnings,example-boss/BossWarnings,https://github.com/example-boss/BossWarnings,"Boss mods, ""lightweight""",2026-09-12T17:28:34+00:00,"bcc,classic,mainline",410001,bW3xQa7k,7001,True,2026-09-18T09:20:16.326671+00:00
        1,Empty,someone/Empty,https://github.com/someone/Empty,,,,,,,False,

        """#
        let entries = CatalogueCSV.entries(from: Data(csv.utf8))
        #expect(entries.count == 2)
        let bw = try #require(entries.first)
        #expect(bw.id == "900000011")
        #expect(bw.name == "BossWarnings")
        #expect(bw.fullName == "example-boss/BossWarnings")
        #expect(bw.url == URL(string: "https://github.com/example-boss/BossWarnings"))
        #expect(bw.description == "Boss mods, \"lightweight\"")
        #expect(bw.lastUpdated == Date(timeIntervalSince1970: 1_789_234_114))
        #expect(bw.flavors == ["bcc", "classic", "mainline"])
        #expect(bw.curseID == 410001)
        #expect(bw.wagoID == "bW3xQa7k")
        #expect(bw.wowiID == 7001)
        #expect(bw.hasReleaseJSON)
        #expect(bw.ref == AddonRef(source: .github, identifier: "example-boss/BossWarnings"))

        let empty = entries[1]
        #expect(empty.description == nil)
        #expect(empty.lastUpdated == nil)
        #expect(empty.flavors.isEmpty)
        #expect(empty.curseID == nil)
        #expect(empty.wagoID == nil)
        #expect(empty.wowiID == nil)
        #expect(!empty.hasReleaseJSON)
    }

    @Test func skipsMalformedRows() {
        let csv = Self.header + #"""
        1,TooFew,a/b,https://github.com/a/b
        2,,a/noname,https://github.com/a/noname,,,,,,,False,
        3,BadName,notarepo,https://github.com/x,,,,,,,False,
        4,BadURL,a/c,,,,,,,,False,
        5,Good,a/good,https://github.com/a/good,"multi
        line",2020-01-01T00:00:00Z,mainline,notanint,,,True,
        6,TooMany,a/d,https://github.com/a/d,,,,,,,False,,extra

        """#
        let entries = CatalogueCSV.entries(from: Data(csv.utf8))
        #expect(entries.map(\.name) == ["Good"])
        #expect(entries.first?.description == "multi\nline")
        #expect(entries.first?.curseID == nil)
    }

    @Test func parsesDateVariants() {
        let base = Date(timeIntervalSince1970: 1_789_724_416)
        #expect(CatalogueCSV.parseDate("2026-09-18T09:40:16+00:00") == base)
        #expect(CatalogueCSV.parseDate("2026-09-18T09:40:16Z") == base)
        #expect(CatalogueCSV.parseDate("2026-09-18T11:40:16+02:00") == base)
        let fractional = CatalogueCSV.parseDate("2026-09-18T09:40:16.326671+00:00")
        #expect(fractional.map { abs($0.timeIntervalSince(base) - 0.326) < 0.01 } == true)
        #expect(CatalogueCSV.parseDate("yesterday") == nil)
    }

    @Test func missingRequiredHeaderYieldsNothing() {
        #expect(CatalogueCSV.entries(from: Data("foo,bar\n1,2\n".utf8)).isEmpty)
    }

    @Test func parsesCatalogueFixture() throws {
        let entries = CatalogueCSV.entries(from: try fixtureData("search/addons.csv"))
        #expect(entries.count == 61)
        let bossWarnings = try #require(entries.first { $0.fullName == "example-boss/BossWarnings" })
        #expect(bossWarnings.hasReleaseJSON)
        #expect(bossWarnings.lastUpdated != nil)
        #expect(entries.contains { $0.description?.contains("\"Quick Sell\"") == true })
        #expect(entries.contains { $0.description?.contains("für Ätherwind") == true })
    }
}

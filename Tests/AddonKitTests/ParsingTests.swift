import Foundation
import Testing
@testable import AddonKit

@Suite struct TocTests {
    @Test func parsesFieldsBOMAndCRLF() {
        let toc = Toc(parsing: "\u{FEFF}## Interface: 120100, 16001\r\n## Title: |cff33ff99Big|rWigs\r\n## X-Website: https://github.com/BigWigsMods/BigWigs\r\nCore.lua\r\n")
        #expect(toc.interfaces == [120100, 16001])
        #expect(toc.title == "BigWigs")
        #expect(toc.website == "https://github.com/BigWigsMods/BigWigs")
        #expect(toc.supports(.forever))
    }

    @Test func caseInsensitiveKeysAndDependencies() {
        let toc = Toc(parsing: "## interface: 16001\n## RequiredDeps: Ace3, LibStub\n## OptionalDeps: Masque")
        #expect(toc["INTERFACE"] == "16001")
        #expect(toc.requiredDependencies == ["Ace3", "LibStub"])
        #expect(toc.optionalDependencies == ["Masque"])
    }

    @Test func doesNotSupportForeverWithRetailOnly() {
        #expect(!Toc(parsing: "## Interface: 120100").supports(.forever))
    }
}

@Suite struct TocFileNameTests {
    @Test(arguments: [
        ("BigWigs_Camelot.toc", "BigWigs", "Camelot"),
        ("DBM-Core-Forever.toc", "DBM-Core", "Forever"),
        ("Plater_Mainline.toc", "Plater", "Mainline"),
        ("Leatrix_Plus.toc", "Leatrix_Plus", nil),
    ])
    func splits(file: String, name: String, suffix: String?) throws {
        let parsed = try #require(TocFileName(file))
        #expect(parsed.addonName == name)
        #expect(parsed.suffix == suffix)
    }

    @Test func flavorChecks() throws {
        #expect(try #require(TocFileName("A_Camelot.toc")).isSpecific(to: .forever))
        #expect(try #require(TocFileName("A_Mainline.toc")).isShared(for: .forever))
        #expect(TocFileName("readme.txt") == nil)
    }
}

@Suite struct ReleaseJSONTests {
    @Test func picksForeverRelease() throws {
        let json = #"{"releases":[{"name":"BigWigs","version":"v426.4","filename":"BigWigs-v426.4.zip","nolib":false,"metadata":[{"flavor":"mainline","interface":120100},{"flavor":"forever","interface":16001}]},{"filename":"BigWigs-v426.4-nolib.zip","nolib":true,"metadata":[{"flavor":"forever","interface":16001}]}]}"#
        let release = try ReleaseJSON(data: Data(json.utf8))
        #expect(release.release(for: .forever)?.filename == "BigWigs-v426.4.zip")
        #expect(release.release(for: .vanilla) == nil)
    }
}

@Suite struct BuildInfoTests {
    @Test func parsesBPSV() {
        let text = """
        Branch!STRING:0|Active!DEC:1|Version!STRING:0|Product!STRING:0
        ## seqn = 1
        us|1|1.60.1.70338|wow_classic_beta
        us|1|12.1.0.65000|wow
        """
        let info = BuildInfo(parsing: text)
        #expect(info.version(forProduct: "wow_classic_beta") == "1.60.1.70338")
        #expect(info.version(forProduct: "wow") == "12.1.0.65000")
    }
}

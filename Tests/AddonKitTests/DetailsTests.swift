import Foundation
import Testing
@testable import AddonKit

@Suite struct ReadmeImagesTests {
    func extract(_ markdown: String, path: String = "README.md") -> [String] {
        ReadmeImages.extract(from: markdown, owner: "o", repo: "r", readmePath: path).map(\.absoluteString)
    }

    @Test func inlineReferenceAndHTMLImagesInDocumentOrder() {
        let markdown = """
            # Addon
            ![Main window](https://i.imgur.com/main.png "The main window")
            <p align="center"><img src="docs/options.png" width="600"></p>
            ![Raid frames][raid]
            ![shortcut]

            [raid]: https://example.com/raid.jpg
            [shortcut]: <img/short cut.png> "Title"
            """
        #expect(extract(markdown) == [
            "https://i.imgur.com/main.png",
            "https://raw.githubusercontent.com/o/r/HEAD/docs/options.png",
            "https://example.com/raid.jpg",
            "https://raw.githubusercontent.com/o/r/HEAD/img/short%20cut.png",
        ])
    }

    @Test func relativePathsResolveAgainstTheReadmeFolder() {
        #expect(extract("![a](./shots/a.png) ![b](../b.png) ![c](/c.png)", path: ".github/README.md") == [
            "https://raw.githubusercontent.com/o/r/HEAD/.github/shots/a.png",
            "https://raw.githubusercontent.com/o/r/HEAD/b.png",
            "https://raw.githubusercontent.com/o/r/HEAD/c.png",
        ])
    }

    @Test func gitHubBlobAndRawLinksBecomeRaw() {
        let markdown = """
            ![a](https://github.com/o/r/blob/main/media/a.png?raw=true)
            ![b](https://github.com/x/y/raw/v1/b.jpg)
            ![c](https://github.com/user-attachments/assets/1234-abcd)
            """
        #expect(extract(markdown) == [
            "https://raw.githubusercontent.com/o/r/main/media/a.png",
            "https://raw.githubusercontent.com/x/y/v1/b.jpg",
            "https://github.com/user-attachments/assets/1234-abcd",
        ])
    }

    @Test func badgesSVGsAndIconsAreDropped() {
        let markdown = """
            [![Build](https://github.com/o/r/actions/workflows/build.yml/badge.svg)](https://github.com/o/r/actions)
            ![Downloads](https://img.shields.io/github/downloads/o/r/total.svg)
            ![Discord](https://discord.com/api/guilds/1/widget.png?style=banner2)
            ![CF](https://cf.way2muchnoise.eu/full_123_downloads.png)
            ![badge](https://example.com/badges/version.png)
            ![logo](https://example.com/logo.svg)
            ![fav](https://example.com/favicon.png)
            ![icon](https://example.com/icon-32x32.png)
            <img src="https://example.com/tiny.png" width="24" height="24">
            <img src='https://example.com/wide.png' width=800>
            ![Screenshot](https://example.com/screenshot.png)
            """
        #expect(extract(markdown) == ["https://example.com/wide.png", "https://example.com/screenshot.png"])
    }

    @Test func codeBlocksCommentsAndDuplicatesAreIgnored() {
        let markdown = """
            ```markdown
            ![not rendered](https://example.com/code.png)
            ```
            <!-- ![hidden](https://example.com/hidden.png) -->
            Use `![x](https://example.com/inline.png)` to add images.
            ![a](https://example.com/a.png) ![again](https://example.com/a.png)
            ![data](data:image/png;base64,AAAA)
            """
        #expect(extract(markdown) == ["https://example.com/a.png"])
    }
}

@Suite struct DetailsTests {
    let ref = AddonRef(source: .github, identifier: "A/Alpha")

    func makeHarness() async throws -> ManagerHarness {
        let h = try await ManagerHarness()
        h.http.stub(CatalogueSource.defaultURL.absoluteString, text: catalogueCSV([("A/Alpha", "Alpha", "2026-09-01T00:00:00Z", true)]))
        _ = try await h.manager.catalogue.refresh(force: true)
        h.http.publishLatest("A/Alpha", tag: "v1")
        h.http.stub("https://raw.githubusercontent.com/A/Alpha/HEAD/.github/README.md", headers: ["ETag": #""r1""#], body: Data("""
            # Alpha
            [![CI](https://img.shields.io/badge/ci-passing-green)](x)
            ![Screenshot](media/shot.png)
            """.utf8))
        h.http.reset()
        return h
    }

    @Test func gathersCatalogueReadmeScreenshotsAndSupport() async throws {
        let h = try await makeHarness()
        let details = try await h.manager.details(for: ref, in: h.installation)
        #expect(details.name == "Alpha")
        #expect(details.owner == "A")
        #expect(details.summary == "Alpha add-on")
        #expect(details.lastUpdated != nil)
        #expect(details.readme?.hasPrefix("# Alpha") == true)
        #expect(details.screenshots.map(\.absoluteString) == ["https://raw.githubusercontent.com/A/Alpha/HEAD/.github/media/shot.png"])
        #expect(details.support == .supported(version: "v1"))
        #expect(details.latestVersion == "v1")
        #expect(await h.manager.catalogueEntry(for: AddonRef(source: .github, identifier: "a/alpha"))?.name == "Alpha")
        // README.md 404s first, then .github/README.md is found.
        #expect(h.http.urls.contains("https://raw.githubusercontent.com/A/Alpha/HEAD/README.md"))
    }

    @Test func detailsAreStoredForADayThenRevalidatedWithTheRememberedPath() async throws {
        let h = try await makeHarness()
        _ = try await h.manager.details(for: ref, in: h.installation)
        h.http.reset()
        _ = try await h.manager.details(for: ref, in: h.installation)
        #expect(h.http.requests.isEmpty, "served from the database")

        await h.manager.setClock { Date().addingTimeInterval(25 * 3600) }
        h.http.stub("https://raw.githubusercontent.com/A/Alpha/HEAD/.github/README.md", status: 304)
        let again = try await h.manager.details(for: ref, in: h.installation)
        let readmeRequests = h.http.requests.filter { $0.url?.host() == "raw.githubusercontent.com" }
        #expect(readmeRequests.map { $0.url!.absoluteString } == ["https://raw.githubusercontent.com/A/Alpha/HEAD/.github/README.md"])
        #expect(readmeRequests.first?.value(forHTTPHeaderField: "If-None-Match") == #""r1""#)
        #expect(again.readme?.hasPrefix("# Alpha") == true)
        #expect(again.screenshots.count == 1)
    }

    @Test func aMissingReadmeIsRememberedAndNeverAsksTheAPIWithoutAToken() async throws {
        let h = try await ManagerHarness()
        let other = AddonRef(source: .github, identifier: "Z/None")
        h.http.publishLatest("Z/None", tag: nil)
        let details = try await h.manager.details(for: other, in: h.installation)
        #expect(details.readme == nil)
        #expect(details.screenshots.isEmpty)
        #expect(details.support == .noReleases)
        #expect(details.name == "None")
        #expect(!h.http.urls.contains { $0.hasSuffix("/readme") })
        h.http.reset()
        _ = try await h.manager.details(for: other, in: h.installation)
        #expect(h.http.requests.isEmpty)
    }

    @Test func networkFailureIsNotStored() async throws {
        let h = try await makeHarness()
        h.http.stub("https://raw.githubusercontent.com/A/Alpha/HEAD/README.md", status: 500)
        await h.manager.setRetryDelay { _, _ in .zero }
        let failed = try await h.manager.details(for: ref, in: h.installation)
        #expect(failed.readme == nil)
        #expect(await h.manager.storedDetails(ref, flavor: .forever) == nil)
    }

    @Test func latestReleaseNotesComeFromTheAPIWhenQuotaAllows() async throws {
        let h = try await makeHarness()
        try h.publish("A/Alpha", [("v1", 1, 3)])
        let details = try await h.manager.details(for: ref, in: h.installation)
        #expect(details.latestChangelog == "Notes for v1")
        #expect(details.latestPublishedAt != nil)
        #expect(h.http.apiRequests.count == 1)
    }

    @Test func largeReadmesAreCapped() {
        let line = String(repeating: "x", count: 99) + "\n"
        let big = Data(String(repeating: line, count: 6_000).utf8)
        let capped = GitHubSource.capped(big)
        #expect(capped.utf8.count <= GitHubSource.maxReadmeBytes)
        #expect(capped.hasSuffix("x"))
    }
}

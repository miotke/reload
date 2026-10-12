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

    func noZips(_ h: ManagerHarness) -> Bool {
        h.transport.requests.isEmpty && !h.http.urls.contains { $0.hasSuffix(".zip") }
    }

    /// A cold open: one HEAD, the release.json for that tag, and the README paths. No API
    /// call and no zip, even for a repo without release.json.
    @Test func openingDetailsSpendsNoQuotaAndDownloadsNoZips() async throws {
        let h = try await makeHarness()
        try h.publish("A/Alpha", [("v1", 1, 3)])
        h.http.reset()
        let details = try await h.manager.details(for: ref, in: h.installation)
        #expect(h.http.apiRequests.isEmpty)
        #expect(noZips(h), "no zip downloads")
        #expect(h.http.urls.filter { $0.hasPrefix("https://github.com/") && $0.hasSuffix("/release.json") }.count == 1, "release.json once")
        #expect(h.http.requests.filter { $0.url?.host() == "github.com" && $0.httpMethod == "HEAD" }.count == 1)
        #expect(details.support == .supported(version: "v1"))
        #expect(details.latestVersion == "v1")
        #expect(details.latestChangelog == nil, "notes are on demand")

        // Without release.json: still nothing but github.com and raw.githubusercontent.com.
        let bare = AddonRef(source: .github, identifier: "B/Bare")
        h.http.publishLatest("B/Bare", tag: "v9", flavors: nil)
        h.http.reset()
        #expect(try await h.manager.details(for: bare, in: h.installation).support == .needsDownload)
        #expect(h.http.apiRequests.isEmpty)
        #expect(noZips(h))
    }

    @Test func releaseNotesAreOneAPICallThenStoredByTag() async throws {
        let h = try await makeHarness()
        try h.publish("A/Alpha", [("v1", 1, 3)])
        h.http.stub("https://api.github.com/repos/A/Alpha/releases/latest", headers: ["x-ratelimit-remaining": "50"], body: Data("""
            {"id": 1, "tag_name": "v1", "draft": false, "prerelease": false, "published_at": "2026-10-03T12:00:00Z",
             "body": "Notes for v1", "assets": []}
            """.utf8))
        _ = try await h.manager.details(for: ref, in: h.installation)
        h.http.reset()

        let notes = try #require(try await h.manager.releaseNotes(for: ref, in: h.installation))
        #expect(notes.version == "v1")
        #expect(notes.markdown == "Notes for v1")
        #expect(notes.publishedAt != nil)
        #expect(h.http.urls == ["https://api.github.com/repos/A/Alpha/releases/latest"])
        #expect(noZips(h))

        // Stored: asking again, or reopening the details, costs nothing and shows them.
        h.http.reset()
        #expect(try await h.manager.releaseNotes(for: ref, in: h.installation)?.markdown == "Notes for v1")
        let details = try await h.manager.details(for: ref, in: h.installation)
        #expect(details.latestChangelog == "Notes for v1")
        #expect(details.latestPublishedAt != nil)
        #expect(h.http.requests.isEmpty)

        // Once the details are revalidated, a new latest tag hides the old notes.
        await h.manager.setClock { Date().addingTimeInterval(25 * 3600) }
        h.http.publishLatest("A/Alpha", tag: "v2")
        #expect(try await h.manager.details(for: ref, in: h.installation).latestChangelog == nil)
    }

    @Test func aStoredNoReadmeIsTrustedForAWeek() async throws {
        let h = try await ManagerHarness()
        let other = AddonRef(source: .github, identifier: "Z/None")
        h.http.publishLatest("Z/None", tag: nil)
        let clock = MutableClock()
        await h.manager.setClock(clock.now)
        _ = try await h.manager.details(for: other, in: h.installation)
        #expect(h.http.urls.filter { $0.contains("raw.githubusercontent.com") }.count == ReadmeFetcher.candidates.count)

        clock.date += 2 * 24 * 3600
        h.http.reset()
        _ = try await h.manager.details(for: other, in: h.installation)
        #expect(!h.http.urls.contains { $0.contains("raw.githubusercontent.com") }, "details are stale, the stored 'none' isn't")

        clock.date += 6 * 24 * 3600
        h.http.reset()
        _ = try await h.manager.details(for: other, in: h.installation)
        #expect(h.http.urls.contains { $0.contains("raw.githubusercontent.com") })
    }

    @Test func largeReadmesAreCapped() {
        let line = String(repeating: "x", count: 99) + "\n"
        let big = Data(String(repeating: line, count: 6_000).utf8)
        let capped = ReadmeFetcher.capped(big)
        #expect(capped.utf8.count <= ReadmeFetcher.maxBytes)
        #expect(capped.hasSuffix("x"))
    }
}

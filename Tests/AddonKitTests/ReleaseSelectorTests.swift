import Foundation
import Testing
@testable import AddonKit

// MARK: - Builders shared by the GitHub tests

func ghAsset(_ id: Int64, _ name: String, repo: String = "o/r", tag: String = "v1", state: String = "uploaded") -> GitHubAsset {
    GitHubAsset(id: id, name: name, state: state, size: 100, contentType: nil,
                browserDownloadURL: URL(string: "https://github.com/\(repo)/releases/download/\(tag)/\(name)")!)
}

func ghRelease(
    _ id: Int64, tag: String, draft: Bool = false, prerelease: Bool = false,
    published: String = "2026-10-01T00:00:00Z", assets: [GitHubAsset]
) -> GitHubRelease {
    GitHubRelease(id: id, tagName: tag, name: tag, draft: draft, prerelease: prerelease,
                  publishedAt: ISO8601DateFormatter().date(from: published), body: "Changes in \(tag)", assets: assets)
}

func ghReleaseJSON(_ entries: [(file: String, nolib: Bool, flavors: [(String, Int)])]) -> ReleaseJSON {
    ReleaseJSON(releases: entries.map { entry in
        ReleaseJSON.Release(name: "Addon", version: nil, filename: entry.file, nolib: entry.nolib,
                            metadata: entry.flavors.map { ReleaseJSON.Metadata(flavor: $0.0, interface: $0.1) })
    })
}

@Suite struct ReleaseSelectorTests {
    @Test func recordedBigWigsPicksForeverZip() throws {
        let releases = try GitHubRelease.decodeList(from: fixtureData("github/bigwigs-releases.json"))
        #expect(releases.count == 3)
        let first = try #require(releases.first)
        let jsonAsset = try #require(first.releaseJSONAsset)

        let ask = ReleaseSelector.select(releases, channel: .stable, flavor: .forever, releaseJSONs: [:])
        guard case .needsReleaseJSON(let release, let asset, _) = ask else {
            Issue.record("expected needsReleaseJSON, got \(ask)")
            return
        }
        #expect(release.id == first.id)
        #expect(asset.id == jsonAsset.id)

        let json = try ReleaseJSON(data: fixtureData("github/bigwigs-release-v426.4.json"))
        let result = ReleaseSelector.select(releases, channel: .stable, flavor: .forever, releaseJSONs: [jsonAsset.id: json])
        guard case .selected(let r, let zip, let reasoning) = result else {
            Issue.record("expected selected, got \(result)")
            return
        }
        #expect(r.tagName == "v426.4")
        #expect(zip.name == "BigWigs-v426.4.zip")
        #expect(reasoning == ["release v426.4 (id 409811185)", "release.json → BigWigs-v426.4.zip (forever 16001)"])
    }

    @Test func dropsDraftsAndPrereleasesOnStable() {
        let json = ghReleaseJSON([("A-3.zip", false, [("forever", 16001)])])
        let releases = [
            ghRelease(4, tag: "v4", draft: true, assets: [ghAsset(40, "A-4.zip"), ghAsset(41, "release.json")]),
            ghRelease(3, tag: "v3-beta", prerelease: true, assets: [ghAsset(30, "A-3.zip"), ghAsset(31, "release.json")]),
            ghRelease(2, tag: "v2", assets: [ghAsset(20, "A-2.zip"), ghAsset(21, "release.json")]),
        ]
        let json2 = ghReleaseJSON([("A-2.zip", false, [("forever", 16001)])])

        let stable = ReleaseSelector.select(releases, channel: .stable, flavor: .forever, releaseJSONs: [31: json, 21: json2])
        guard case .selected(let r, let asset, let reasoning) = stable else {
            Issue.record("expected selected, got \(stable)")
            return
        }
        #expect(r.id == 2)
        #expect(asset.name == "A-2.zip")
        #expect(reasoning.first == "skipped draft v4 (id 4)")
        #expect(reasoning.contains("skipped prerelease v3-beta (id 3)"))

        let pre = ReleaseSelector.select(releases, channel: .prerelease, flavor: .forever, releaseJSONs: [31: json, 21: json2])
        guard case .selected(let pr, _, _) = pre else {
            Issue.record("expected selected, got \(pre)")
            return
        }
        #expect(pr.id == 3)
        #expect(ReleaseSelector.eligible(releases, channel: .stable).map(\.id) == [2])
    }

    @Test func prereleaseOnlyOnStableIsNone() {
        let releases = [ghRelease(1, tag: "v1-alpha", prerelease: true, assets: [ghAsset(10, "A.zip")])]
        guard case .none(let reasoning) = ReleaseSelector.select(releases, channel: .stable, flavor: .forever, releaseJSONs: [:]) else {
            Issue.record("expected none")
            return
        }
        #expect(reasoning.last == "no release supports forever")
    }

    @Test func newestWithoutForeverFallsBackToOlder() {
        let releases = [
            ghRelease(2, tag: "v2", assets: [ghAsset(20, "A-v2.zip"), ghAsset(21, "release.json")]),
            ghRelease(1, tag: "v1", assets: [ghAsset(10, "A-v1.zip"), ghAsset(11, "release.json")]),
        ]
        let jsons: [Int64: ReleaseJSON] = [
            21: ghReleaseJSON([("A-v2.zip", false, [("mainline", 120100), ("classic", 11508)])]),
            11: ghReleaseJSON([("A-v1.zip", false, [("mainline", 120100), ("forever", 16001)])]),
        ]
        let result = ReleaseSelector.select(releases, channel: .stable, flavor: .forever, releaseJSONs: jsons)
        guard case .selected(let r, let asset, let reasoning) = result else {
            Issue.record("expected selected, got \(result)")
            return
        }
        #expect(r.id == 1)
        #expect(asset.name == "A-v1.zip")
        #expect(reasoning.contains("release.json has no forever entry; trying older release"))
        // Asks for the older release.json first when it isn't loaded.
        let ask = ReleaseSelector.select(releases, channel: .stable, flavor: .forever, releaseJSONs: [21: jsons[21]!])
        guard case .needsReleaseJSON(let rr, let a, _) = ask else {
            Issue.record("expected needsReleaseJSON, got \(ask)")
            return
        }
        #expect(rr.id == 1 && a.id == 11)
    }

    @Test func nolibEntriesAndAssetsSkipped() {
        let release = ghRelease(1, tag: "v1", assets: [
            ghAsset(10, "A-v1-nolib.zip"), ghAsset(11, "A-v1.zip"), ghAsset(12, "release.json"),
        ])
        let json = ghReleaseJSON([
            ("A-v1-nolib.zip", true, [("forever", 16001)]),
            ("A-v1.zip", false, [("forever", 16001)]),
        ])
        guard case .selected(_, let asset, _) = ReleaseSelector.select([release], channel: .stable, flavor: .forever, releaseJSONs: [12: json]) else {
            Issue.record("expected selected")
            return
        }
        #expect(asset.name == "A-v1.zip")
        #expect(ReleaseSelector.zipCandidates(release, flavor: .forever).map(\.name) == ["A-v1.zip"])

        let onlyNolib = ghReleaseJSON([("A-v1-nolib.zip", true, [("forever", 16001)])])
        guard case .none = ReleaseSelector.select([release], channel: .stable, flavor: .forever, releaseJSONs: [12: onlyNolib]) else {
            Issue.record("expected none")
            return
        }
    }

    @Test func noReleaseJSONNeedsInspectionThenMovesOn() {
        let releases = [
            ghRelease(3, tag: "v3", assets: [ghAsset(30, "A-v3.zip"), ghAsset(31, "A-v3-classic.zip"), ghAsset(32, "A-v3-forever.zip"), ghAsset(33, "A-v3-nolib.zip"), ghAsset(34, "notes.txt"), ghAsset(35, "B.zip", state: "open")]),
            ghRelease(2, tag: "v2", assets: [ghAsset(20, "Source.tar.gz")]),
            ghRelease(1, tag: "v1", assets: [ghAsset(10, "A-v1.zip")]),
        ]
        let first = ReleaseSelector.select(releases, channel: .stable, flavor: .forever, releaseJSONs: [:])
        guard case .needsInspection(let r, let candidates, _) = first else {
            Issue.record("expected needsInspection, got \(first)")
            return
        }
        #expect(r.id == 3)
        #expect(candidates.map(\.name) == ["A-v3-forever.zip", "A-v3.zip", "A-v3-classic.zip"])

        let next = ReleaseSelector.select(releases, channel: .stable, flavor: .forever, releaseJSONs: [:], excluding: [3])
        guard case .needsInspection(let r1, let c1, let reasoning) = next else {
            Issue.record("expected needsInspection, got \(next)")
            return
        }
        #expect(r1.id == 1)
        #expect(c1.map(\.name) == ["A-v1.zip"])
        #expect(reasoning.contains("no zip assets; trying older release"))

        guard case .none = ReleaseSelector.select(releases, channel: .stable, flavor: .forever, releaseJSONs: [:], excluding: [3, 1]) else {
            Issue.record("expected none")
            return
        }
    }

    @Test func unreadableReleaseJSONFallsBackToInspection() {
        let release = ghRelease(1, tag: "v1", assets: [ghAsset(10, "A.zip"), ghAsset(11, "release.json")])
        let result = ReleaseSelector.select([release], channel: .stable, flavor: .forever, releaseJSON: { _ in .unavailable })
        guard case .needsInspection(_, let candidates, _) = result else {
            Issue.record("expected needsInspection, got \(result)")
            return
        }
        #expect(candidates.map(\.name) == ["A.zip"])
    }

    @Test func releaseJSONFilenameWithoutAssetMovesOn() {
        let releases = [
            ghRelease(2, tag: "v2", assets: [ghAsset(20, "Other.zip"), ghAsset(21, "release.json")]),
        ]
        let json = ghReleaseJSON([("A-v2.zip", false, [("forever", 16001)])])
        guard case .none(let reasoning) = ReleaseSelector.select(releases, channel: .stable, flavor: .forever, releaseJSONs: [21: json]) else {
            Issue.record("expected none")
            return
        }
        #expect(reasoning.contains { $0.contains("no such asset") })
    }

    @Test func emptyIsNone() {
        #expect(ReleaseSelector.select([], channel: .stable, flavor: .forever, releaseJSONs: [:]) == .none(reasoning: ["no releases"]))
    }
}

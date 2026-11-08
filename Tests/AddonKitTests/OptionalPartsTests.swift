import Foundation
import Synchronization
import Testing
@testable import AddonKit

/// A repo shaped like Spoken: an add-on, voice packs and a desktop app, told apart by tag
/// prefix (docs/features/optional-parts.md). Nothing here is specific to that repo.
struct StreamRepo {
    static let name = "rk/voices"
    static let main = AddonRef(source: .github, identifier: name)
    static let places = AddonRef(source: .github, identifier: name, tagPrefix: "places-audio")

    struct Release {
        var tag: String
        var id: Int64
        var assets: [(name: String, size: Int)]
        var prerelease = false
    }

    let h: ManagerHarness
    var releases: [Release]

    static func standard() -> [Release] {
        [
            Release(tag: "voices/v3.8.4", id: 384, assets: [("Voices-3.8.4.zip", 72_000_000)]),
            Release(tag: "manager/v0.1.12", id: 112, assets: [("App-0.1.12-mac-arm64.zip", 140_000_000), ("App-0.1.12-mac-arm64.dmg", 140_000_000)]),
            Release(tag: "voices/v3.8.4-beta.1", id: 383, assets: [("Voices-3.8.4-beta.1.zip", 72_000_000)], prerelease: true),
            Release(tag: "places-audio/v2.1.0", id: 210, assets: [("VoicesPlacesAudio-2.1.0.zip", 456_000_000)]),
            Release(tag: "zones-audio-deDE/v2.1.1", id: 211, assets: [("VoicesZonesAudio_deDE-2.1.1.zip", 470_000_000)]),
            Release(tag: "quests-audio-deDE/v1.0.1", id: 101, assets: [("VoicesQuestsAudio_deDE-1.0.1.zip", 1_600_000_000)]),
            Release(tag: "quests-audio-esES/v0.0.6", id: 6, assets: [("VoicesQuestsAudio_esES-0.0.6.zip", 1_300_000_000)]),
            Release(tag: "zones-audio/v2.0.1", id: 201, assets: [("VoicesZonesAudio-2.0.1.zip", 469_000_000)]),
        ]
    }

    init(_ h: ManagerHarness, releases: [Release] = StreamRepo.standard()) throws {
        self.h = h
        self.releases = releases
        try publish()
    }

    static func url(_ asset: String, tag: String) -> String { "https://downloads.test/\(name)/\(tag)/\(asset)" }

    /// Stubs the releases API (10 and 100 per page), `releases/latest` (the newest stable,
    /// without release.json) and every zip. `Voices-*.zip` ships `Voices` and `Voices_Places`,
    /// whose TOC lists the packs in `OptionalDeps`.
    func publish(etag: String = #""listing-1""#) throws {
        var json: [[String: Any]] = []
        for release in releases {
            var assets: [[String: Any]] = []
            for (i, asset) in release.assets.enumerated() {
                assets.append([
                    "id": release.id * 10 + Int64(i), "name": asset.name, "state": "uploaded", "size": asset.size,
                    "browser_download_url": Self.url(asset.name, tag: release.tag),
                ])
                guard asset.name.hasSuffix(".zip") else { continue }
                let dir = try makeTempDirectory()
                let zip: URL
                if asset.name.hasPrefix("Voices-") {
                    zip = try makeTestZip([
                        .file("Voices/Voices.toc", "## Interface: 16001\n## Title: Voices\n"),
                        .file("Voices_Places/Voices_Places.toc",
                              "## Interface: 16001\n## Dependencies: Voices\n## OptionalDeps: VoicesPlacesAudio, ZoneLoreAudio, VoicesZonesAudio, VoicesQuestsAudio, Voices\n"),
                    ], named: asset.name, in: dir)
                } else {
                    let folder = String(asset.name.prefix { $0 != "-" })
                    zip = try makeAddonZip(folders: [folder], marker: release.tag, named: asset.name, in: dir)
                }
                let data = try Data(contentsOf: zip)
                h.transport.stub(URL(string: Self.url(asset.name, tag: release.tag))!, data)
                // Inspection downloads through the HTTP client.
                h.http.stub(Self.url(asset.name, tag: release.tag), body: data)
            }
            json.append([
                "id": release.id, "tag_name": release.tag, "draft": false, "prerelease": release.prerelease,
                // Later ids are later releases within a stream, wherever they sit in the list.
                "published_at": Date(timeIntervalSince1970: 1_790_000_000 + Double(release.id) * 60).ISO8601Format(),
                "body": "Notes for \(release.tag)",
                "assets": assets,
            ])
        }
        let body = try JSONSerialization.data(withJSONObject: json)
        let headers = ["x-ratelimit-remaining": "55", "ETag": etag]
        h.http.stub("https://api.github.com/repos/\(Self.name)/releases?per_page=100", headers: headers, body: body)
        h.http.stub("https://api.github.com/repos/\(Self.name)/releases?per_page=10", headers: headers,
                    body: try JSONSerialization.data(withJSONObject: Array(json.prefix(10))))
        h.http.publishLatest(Self.name, tag: releases.first { !$0.prerelease }?.tag, flavors: nil)
    }

    var listingRequests: Int { h.http.apiRequests.filter { $0.url!.absoluteString.contains("per_page=100") }.count }
    var downloads: [String] { h.transport.requests.map(\.lastPathComponent) }
}

@Suite struct ReleaseStreamTests {
    func release(_ tag: String, _ assets: [String], prerelease: Bool = false) -> GitHubRelease {
        GitHubRelease(id: Int64(abs(tag.hashValue % 100_000)), tagName: tag, prerelease: prerelease, assets: assets.enumerated().map {
            GitHubAsset(id: Int64($0.offset), name: $0.element, size: 10, browserDownloadURL: URL(string: "https://x.test/\($0.element)")!)
        })
    }

    @Test func prefixesAndVersions() {
        #expect(ReleaseStreams.prefix(ofTag: "places-audio/v2.1.0") == "places-audio")
        #expect(ReleaseStreams.prefix(ofTag: "v1.2") == nil)
        #expect(ReleaseStreams.prefix(ofTag: "manager-latest") == nil)
        #expect(ReleaseStreams.prefix(ofTag: "/v1") == nil)
        #expect(ReleaseStreams.version(ofTag: "places-audio/v2.1.0") == "2.1.0")
        #expect(ReleaseStreams.stem(of: "Voices-3.8.4.zip", tag: "voices/v3.8.4") == ReleaseStreams.stem(of: "Voices-3.8.5.zip", tag: "voices/v3.8.5"))
        #expect(ReleaseStreams.stem(of: "Q-WoW_1.12-2.2.2.zip", tag: "q/v2.2.2") != ReleaseStreams.stem(of: "Q-WoW_2.4.3-2.2.2.zip", tag: "q/v2.2.2"))
        #expect(ReleaseStreams.followedPrefix(ref: StreamRepo.main, installedTag: "voices/v3.8.4") == "voices")
        #expect(ReleaseStreams.followedPrefix(ref: StreamRepo.places, installedTag: "v1") == "places-audio")
        #expect(ReleaseStreams.followedPrefix(ref: AddonRef(source: .wowinterface, identifier: "1"), installedTag: "a/b") == nil)
    }

    @Test func matchingPicksTheOneStream() {
        let releases = [
            release("zones-audio-deDE/v2.1.1", ["PackZones_deDE-2.1.1.zip"]),
            release("places/v2.1.0", ["PackPlaces-2.1.0.zip"]),
            release("places/v2.0.0", ["PackPlaces-2.0.0.zip"]),
            release("zones-audio/v2.0.1", ["PackZones-2.0.1.zip"]),
            release("q-de/v1", ["PackQ_deDE-1.zip"]),
            release("q-es/v1", ["PackQ_esES-1.zip"]),
            release("beta/v9", ["PackBeta-9.zip"], prerelease: true),
        ]
        let places = ReleaseStreams.match(folder: "packplaces", in: releases)
        #expect(places?.prefix == "places")
        #expect(places?.release.tagName == "places/v2.1.0", "the stream's latest stable")
        #expect(ReleaseStreams.match(folder: "PackZones", in: releases)?.prefix == "zones-audio", "a versioned name beats a language pack")
        #expect(ReleaseStreams.match(folder: "PackQ", in: releases) == nil, "two language packs: ambiguous")
        #expect(ReleaseStreams.match(folder: "PackBeta", in: releases) == nil, "prereleases only")
        #expect(ReleaseStreams.match(folder: "Pack", in: releases) == nil)
        #expect(ReleaseStreams.match(folder: "PackPlaces", in: releases, excluding: ["places"]) == nil)
    }

    @Test func desktopReleasesAreNeverCandidates() {
        let app = release("manager/v1", ["App-1-mac-arm64.zip", "App-1.dmg"])
        #expect(ReleaseStreams.shipsDesktopApp(app))
        #expect(ReleaseSelector.zipCandidates(release("x/v1", ["App-1-mac-arm64.zip", "Addon-1.zip"]), flavor: .forever).map(\.name) == ["Addon-1.zip"])
        guard case .needsInspection(let picked, _, let reasoning) = ReleaseSelector.select(
            [app, release("addon/v1", ["Addon-1.zip"])], channel: .stable, flavor: .forever, releaseJSONs: [:]) else {
            Issue.record("expected the add-on release")
            return
        }
        #expect(picked.tagName == "addon/v1")
        #expect(reasoning.contains { $0.contains("desktop app") })
    }

    @Test func trimmingKeepsAFewPerStream() {
        let many = (0..<10).map { release("s/v\(10 - $0)", ["S-\(10 - $0).zip"]) } + [release("v1", ["Plain.zip"])]
        let kept = ReleaseStreams.trimmed(many)
        #expect(kept.map(\.tagName) == ["s/v10", "s/v9", "s/v8"])
    }

    @Test func refsWithAPrefixParseAndRoundTrip() {
        let ref = AddonRef(parsing: "rk/voices#places-audio")
        #expect(ref == StreamRepo.places)
        #expect(AddonRef(parsing: "github:rk/voices#places-audio") == StreamRepo.places)
        #expect(AddonRef(parsing: "https://github.com/rk/voices#readme") == StreamRepo.main, "a URL's fragment is an anchor")
        #expect(AddonRef(parsing: "rk/voices#") == nil)
        #expect(AddonRef(parsing: "rk/voices#a/b") == nil)
        #expect(StreamRepo.places.key == "rk/voices#places-audio")
        #expect(AddonRef(key: StreamRepo.places.key) == StreamRepo.places)
        #expect(StreamRepo.places.repo == StreamRepo.main)
        #expect(StreamRepo.places.isSameRepo(as: StreamRepo.main))
        #expect(!StreamRepo.places.isSameAddon(as: StreamRepo.main))
        #expect(StreamRepo.places.isSameAddon(as: AddonRef(source: .github, identifier: "RK/Voices", tagPrefix: "Places-Audio")))
        let decoded = try? JSONDecoder().decode(AddonRef.self, from: Data(#"{"source":"github","identifier":"rk/voices"}"#.utf8))
        #expect(decoded == StreamRepo.main, "older stored refs have no prefix")
    }

    @Test func largeArchivesGetRoomToUnpack() {
        #expect(ZipExtractor.limits(forArchiveSize: 5_000_000).bytes == ZipExtractor.maxUncompressedBytes)
        #expect(ZipExtractor.limits(forArchiveSize: 5_000_000).entries == ZipExtractor.maxEntries)
        let pack = ZipExtractor.limits(forArchiveSize: 1_600_000_000)
        #expect(pack.bytes == 3_200_000_000)
        #expect(pack.entries > ZipExtractor.maxEntries)
        #expect(ZipExtractor.limits(forArchiveSize: 100_000_000_000).bytes == ZipExtractor.ceilingBytes)
    }

    @Test func partsCacheTheirZipsApartFromTheirAddOn() {
        let downloader = Downloader(cachesDirectory: URL(filePath: "/tmp/x"), transport: StubDownloadTransport())
        #expect(downloader.addonDirectory(for: StreamRepo.places).lastPathComponent == "rk+voices+places-audio")
        #expect(downloader.addonDirectory(for: StreamRepo.main).lastPathComponent == "rk+voices")
        #expect(downloader.addonDirectory(for: AddonRef(source: .wowinterface, identifier: "3826")).lastPathComponent == "3826")
    }
}

@Suite struct OptionalPartsTests {
    /// Installs the whole repo the way 0.1.9 did (a plain ref), with the app's stream newest.
    func installedRepo() async throws -> (ManagerHarness, StreamRepo) {
        let h = try await ManagerHarness()
        var repo = try StreamRepo(h)
        repo.releases.swapAt(0, 1)
        try repo.publish()
        try await h.manager.install(StreamRepo.main, into: h.installation)
        h.http.reset()
        return (h, repo)
    }

    @Test func aPlainInstallSkipsTheDesktopApp() async throws {
        let (h, repo) = try await installedRepo()
        let addon = try #require(try await h.manager.installedAddons(in: h.installation).first)
        #expect(addon.version == "voices/v3.8.4")
        #expect(addon.folders.sorted() == ["Voices", "Voices_Places"])
        #expect(!h.transport.requests.contains { $0.lastPathComponent.contains("App-") }, "never downloads the app to look inside")
        _ = repo
    }

    @Test func partsAreFoundWithStates() async throws {
        let (h, repo) = try await installedRepo()
        // The user already has one pack in AddOns/, unmanaged.
        try FileManager.default.createDirectory(
            at: h.installation.addonsDirectory.appending(path: "VoicesZonesAudio"), withIntermediateDirectories: true)

        #expect(try await h.manager.optionalParts(of: StreamRepo.main, in: h.installation, policy: .preferStored).isEmpty)
        #expect(h.http.requests.isEmpty, ".preferStored makes no requests")

        let parts = try await h.manager.optionalParts(of: StreamRepo.main, in: h.installation, policy: .revalidateIfStale)
        #expect(parts.map(\.folder) == ["VoicesPlacesAudio", "VoicesZonesAudio"], "ZoneLoreAudio isn't published, VoicesQuestsAudio is ambiguous")
        let places = try #require(parts.first)
        #expect(places.ref == StreamRepo.places)
        #expect(places.state == .available)
        #expect(places.version == "places-audio/v2.1.0")
        #expect(places.downloadSize == 456_000_000)
        #expect(places.usedBy == ["Voices_Places"])
        #expect(parts[1].state == .unmanaged)
        #expect(parts[1].ref.tagPrefix == "zones-audio")
        #expect(repo.listingRequests == 1)
        #expect(h.http.apiRequests.count == 1)
        #expect(repo.downloads.isEmpty)

        // Stored now: the same answer offline, and no API call while the latest tag stands.
        h.http.reset()
        #expect(try await h.manager.optionalParts(of: StreamRepo.main, in: h.installation, policy: .preferStored) == parts)
        #expect(h.http.requests.isEmpty)
        #expect(try await h.manager.optionalParts(of: StreamRepo.main, in: h.installation, policy: .revalidateIfStale) == parts)
        #expect(h.http.apiRequests.isEmpty)
        let fresh = await h.reopen()
        #expect(try await fresh.optionalParts(of: StreamRepo.main, in: h.installation, policy: .forceRevalidate) == parts)
        #expect(h.http.apiRequests.isEmpty, "an unchanged latest tag means the stored listing is current")
    }

    @Test func noPartsWithoutOptionalDepsOrForOtherSources() async throws {
        let h = try await ManagerHarness()
        try h.publish("Test/Addon", [("v1", 1, 1)])
        try await h.manager.install(AddonRef(source: .github, identifier: "Test/Addon"), into: h.installation)
        h.http.reset()
        #expect(try await h.manager.optionalParts(of: AddonRef(source: .github, identifier: "Test/Addon"), in: h.installation, policy: .forceRevalidate).isEmpty)
        #expect(h.http.requests.isEmpty, "nothing to look up without OptionalDeps")
        #expect(try await h.manager.optionalParts(of: AddonRef(source: .wowinterface, identifier: "1"), in: h.installation, policy: .forceRevalidate).isEmpty)
        #expect(try await h.manager.optionalParts(of: StreamRepo.main, in: h.installation, policy: .forceRevalidate).isEmpty, "not installed")
    }

    @Test func aPartInstallsAndUpdatesWithinItsStream() async throws {
        let (h, repo) = try await installedRepo()
        let part = try await h.manager.install(StreamRepo.places, into: h.installation)
        #expect(part.id == StreamRepo.places)
        #expect(part.name == "VoicesPlacesAudio")
        #expect(part.version == "places-audio/v2.1.0")
        #expect(part.folders == ["VoicesPlacesAudio"])
        #expect(repo.downloads == ["VoicesPlacesAudio-2.1.0.zip"], "downloaded once, for the install")
        let parts = try await h.manager.optionalParts(of: StreamRepo.main, in: h.installation, policy: .preferStored)
        #expect(parts.first?.state == .installed)

        // A new release of the add-on's own stream isn't an update for the pack.
        var next = repo
        next.releases.insert(StreamRepo.Release(tag: "voices/v3.8.5", id: 385, assets: [("Voices-3.8.5.zip", 72_000_000)]), at: 0)
        try next.publish(etag: #""listing-2""#)
        h.http.reset()
        h.transport.reset()
        let states = try await h.manager.checkForUpdates(in: h.installation)
        #expect(states[StreamRepo.places] == .upToDate)
        guard case .available(let release) = states[StreamRepo.main] else {
            Issue.record("expected the add-on's update")
            return
        }
        #expect(release.version == "voices/v3.8.5")
        #expect(release.ref == StreamRepo.main)
        #expect(repo.listingRequests == 1, "one listing for both")
        #expect(!h.http.apiRequests.contains { $0.url!.absoluteString.contains("per_page=10") && !$0.url!.absoluteString.contains("per_page=100") })
        #expect(h.transport.requests.isEmpty, "no zip downloaded to inspect")

        // A pack release is the pack's update only.
        next.releases.insert(StreamRepo.Release(tag: "places-audio/v2.2.0", id: 220, assets: [("VoicesPlacesAudio-2.2.0.zip", 460_000_000)]), at: 0)
        try next.publish(etag: #""listing-3""#)
        let later = try await h.manager.checkForUpdates(in: h.installation)
        guard case .available(let pack) = later[StreamRepo.places] else {
            Issue.record("expected the pack's update")
            return
        }
        #expect(pack.version == "places-audio/v2.2.0")
        guard case .available(let main) = later[StreamRepo.main] else {
            Issue.record("expected the add-on update to stay: \(String(describing: later[StreamRepo.main]))")
            return
        }
        #expect(main.version == "voices/v3.8.5")
    }

    @Test func aPlainRefNeverMovesToAnotherStream() async throws {
        let (h, repo) = try await installedRepo()
        // The app ships again: the repo's latest tag is now another stream's.
        var next = repo
        next.releases.insert(StreamRepo.Release(tag: "manager/v0.1.13", id: 113, assets: [("App-0.1.13-mac-arm64.zip", 140_000_000), ("App-0.1.13.dmg", 1)]), at: 0)
        try next.publish(etag: #""listing-2""#)
        h.transport.reset()

        #expect(try await h.manager.checkForUpdates(in: h.installation)[StreamRepo.main] == .upToDate)
        #expect(h.transport.requests.isEmpty)
        #expect(repo.listingRequests == 1)
        h.http.reset()
        #expect(try await h.manager.checkForUpdates(in: h.installation)[StreamRepo.main] == .upToDate)
        #expect(h.http.apiRequests.isEmpty, "the latest tag hasn't moved since the listing")

        // Repairing or resolving it again stays in its stream too.
        let resolved = try await h.manager.resolve(StreamRepo.main, for: h.installation, channel: .stable)
        #expect(resolved.version == "voices/v3.8.4")
    }

    @Test func anUnmanagedPartFolderIsAdopted() async throws {
        let (h, _) = try await installedRepo()
        let folder = h.installation.addonsDirectory.appending(path: "VoicesPlacesAudio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "## Interface: 16001\n".write(to: folder.appending(path: "VoicesPlacesAudio.toc"), atomically: true, encoding: .utf8)

        let parts = try await h.manager.optionalParts(of: StreamRepo.main, in: h.installation, policy: .revalidateIfStale)
        let part = try #require(parts.first { $0.folder == "VoicesPlacesAudio" })
        #expect(part.state == .unmanaged)
        let ticks = ProgressTicks()
        let adopted = try await h.manager.adopt(folder: part.folder, as: part.ref, in: h.installation, progress: { ticks.add($0) })
        #expect(adopted.id == StreamRepo.places)
        #expect(ticks.last == 1)
        let after = try await h.manager.optionalParts(of: StreamRepo.main, in: h.installation, policy: .preferStored)
        #expect(after.first { $0.folder == "VoicesPlacesAudio" }?.state == .installed)
    }

    @Test func aPartsDetailsComeFromItsStream() async throws {
        let (h, _) = try await installedRepo()
        let details = try await h.manager.details(for: StreamRepo.places, in: h.installation)
        #expect(details.latestVersion == "places-audio/v2.1.0")
        #expect(details.support == .needsDownload)
        let notes = try await h.manager.releaseNotes(for: StreamRepo.places, in: h.installation)
        #expect(notes?.markdown == "Notes for places-audio/v2.1.0")
    }

    @Test func lookupByRepoNamePrefersTheAddOn() async throws {
        let (h, _) = try await installedRepo()
        try await h.manager.install(StreamRepo.places, into: h.installation)
        #expect(try await h.manager.lookup("voices", in: h.installation) == [StreamRepo.main])
        #expect(try await h.manager.lookup("VoicesPlacesAudio", in: h.installation) == [StreamRepo.places])
    }
}

final class ProgressTicks: Sendable {
    private let values = Mutex<[Double]>([])
    func add(_ value: Double) { values.withLock { $0.append(value) } }
    var last: Double? { values.withLock { $0.last } }
}

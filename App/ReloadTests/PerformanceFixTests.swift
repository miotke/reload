import AddonKit
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

/// Serves `https://shots.test/<name>` from `StubImageProtocol.responses`, counting requests.
nonisolated final class StubImageProtocol: URLProtocol {
    struct Response: Sendable {
        var headers: [String: String]
        var body: Data
    }

    static let responses = Mutex<[String: Response]>([:])
    static let hits = Mutex<[String: Int]>([:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "shots.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.hits.withLock { $0[url.absoluteString, default: 0] += 1 }
        guard let stub = Self.responses.withLock({ $0[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In chunks, the way the network delivers a body.
        var offset = 0
        while offset < stub.body.count {
            let end = min(offset + 64 * 1024, stub.body.count)
            client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func serve(_ name: String, body: Data, type: String = "image/png", contentLength: Bool = true) -> URL {
        let url = "https://shots.test/\(name)"
        var headers = ["Content-Type": type]
        if contentLength { headers["Content-Length"] = "\(body.count)" }
        responses.withLock { $0[url] = Response(headers: headers, body: body) }
        return URL(string: url)!
    }

    static func hitCount(_ url: URL) -> Int { hits.withLock { $0[url.absoluteString] ?? 0 } }
}

func pngData(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite(.serialized) struct ScreenshotLoaderTests {
    func loader(_ directory: URL) -> ScreenshotLoader {
        ScreenshotLoader(directory: directory, protocolClasses: [StubImageProtocol.self])
    }

    func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ScreenshotLoaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theCacheLivesInTheDataFoldersCaches() {
        let root = URL(filePath: "/tmp/addons-data", directoryHint: .isDirectory)
        let directories = AppEnvironment.directories(environment: ["RELOAD_DATA_DIR": root.path(percentEncoded: false)])
        #expect(directories.screenshotsDirectory.path(percentEncoded: false).hasPrefix(root.appending(path: "Caches").path(percentEncoded: false)))
        #expect(AppDirectories.standard().screenshotsDirectory.lastPathComponent == "screenshots")
        #expect(AppDirectories.standard().screenshotsDirectory.deletingLastPathComponent() == AppDirectories.standard().caches)
    }

    /// Downloaded once: a second loader over the same folder (a relaunch) reads the disk cache.
    @Test func responsesLandInTheDiskCache() async throws {
        let directory = try tempDirectory()
        let url = StubImageProtocol.serve("cached-\(UUID().uuidString).png", body: try pngData(width: 640, height: 400))
        let first = loader(directory)
        let image = try await first.image(at: url, maxPixelSize: 300)
        #expect(max(image.width, image.height) == 300, "downsampled to the requested size")
        #expect(StubImageProtocol.hitCount(url) == 1)
        #expect(first.cache.cachedResponse(for: URLRequest(url: url)) != nil)

        // URLCache writes to disk in the background; a real relaunch comes long after that.
        let deadline = ContinuousClock.now + .seconds(5)
        while URLCache(memoryCapacity: 0, diskCapacity: 200 * 1024 * 1024, directory: directory)
            .cachedResponse(for: URLRequest(url: url)) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let relaunched = loader(directory)
        _ = try await relaunched.image(at: url, maxPixelSize: 150)
        #expect(StubImageProtocol.hitCount(url) == 1, "served from the disk cache")
        #expect(relaunched.cache.currentDiskUsage > 0)
    }

    @Test func oversizedImagesAreRefusedWithOrWithoutALength() async throws {
        let directory = try tempDirectory()
        let big = Data(count: ScreenshotLoader.maxBytes + 1)
        let declared = StubImageProtocol.serve("big-\(UUID().uuidString).png", body: big)
        await #expect(throws: ScreenshotLoader.Failure.tooLarge) { _ = try await loader(directory).bytes(at: declared) }
        let streamed = StubImageProtocol.serve("stream-\(UUID().uuidString).png", body: big, contentLength: false)
        await #expect(throws: ScreenshotLoader.Failure.tooLarge) { _ = try await loader(directory).bytes(at: streamed) }
        #expect(loader(directory).cache.cachedResponse(for: URLRequest(url: streamed)) == nil, "nothing refused is cached")
    }

    @Test func nonImagesAndSVGsAreRefused() async throws {
        let directory = try tempDirectory()
        let svg = StubImageProtocol.serve("logo-\(UUID().uuidString).svg", body: Data("<svg/>".utf8), type: "image/svg+xml")
        await #expect(throws: ScreenshotLoader.Failure.notAnImage) { _ = try await loader(directory).bytes(at: svg) }
        let html = StubImageProtocol.serve("page-\(UUID().uuidString)", body: Data("<html>".utf8), type: "text/html")
        await #expect(throws: ScreenshotLoader.Failure.notAnImage) { _ = try await loader(directory).bytes(at: html) }
    }

    /// How many decodes run at once, and the most there ever were. A class, so the task
    /// group's closures capture one `Sendable` reference: Xcode 26's compiler rejects
    /// sending a closure that captures the `Mutex` itself from main-actor code.
    nonisolated final class Concurrency: Sendable {
        private let state = Mutex((running: 0, peak: 0))

        func enter() { state.withLock { $0.running += 1; $0.peak = max($0.peak, $0.running) } }
        func leave() { state.withLock { $0.running -= 1 } }
        var peak: Int { state.withLock { $0.peak } }
    }

    @Test func decodeSlotsCapConcurrency() async {
        let slots = DecodeSlots(count: 3)
        let concurrency = Concurrency()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await slots.acquire()
                    concurrency.enter()
                    try? await Task.sleep(for: .milliseconds(20))
                    concurrency.leave()
                    await slots.release()
                }
            }
        }
        #expect(concurrency.peak == 3)
    }
}

@Suite struct InlineMarkdownTests {
    @Test func inlineTextIsRenderedWhileParsing() throws {
        let base = URL(string: "https://github.com/o/r/blob/HEAD/")!
        let blocks = MarkdownParser.renderedBlocks(from: "Read **this** and [setup](docs/setup.md).", baseURL: base)
        guard case .paragraph(let text) = try #require(blocks.first) else {
            Issue.record("expected a paragraph")
            return
        }
        let attributed = try #require(text.attributed)
        #expect(String(attributed.characters) == "Read this and setup.")
        let link = attributed.runs.compactMap(\.link).first
        #expect(link?.absoluteString == "https://github.com/o/r/blob/HEAD/docs/setup.md")
        // Equality is by source, so parser tests compare plain text.
        #expect(blocks == [.paragraph("Read **this** and [setup](docs/setup.md).")])
    }
}

@Suite struct MarkdownLinkTests {
    /// A README can't make a click open a local file or another app.
    @Test func onlyWebLinksStayClickable() throws {
        let base = URL(string: "https://github.com/o/r/blob/HEAD/")!
        let text = InlineText("[web](https://example.com) [file](file:///Applications/Calculator.app) [app](x-apple.systempreferences:x) [rel](docs/a.md)").rendered(baseURL: base)
        let links = try #require(text.attributed).runs.compactMap(\.link).map(\.absoluteString)
        #expect(links == ["https://example.com", "https://github.com/o/r/blob/HEAD/docs/a.md"])
        #expect(String(try #require(text.attributed).characters) == "web file app rel")
    }
}

@Suite struct RecentKeysTests {
    @Test func evictsTheLeastRecentlyUsed() {
        var keys = RecentKeys<Int>(limit: 3)
        #expect(keys.use(1).isEmpty && keys.use(2).isEmpty && keys.use(3).isEmpty)
        #expect(keys.use(1).isEmpty, "reusing doesn't evict")
        #expect(keys.use(4) == [2])
        #expect(keys.keys == [3, 1, 4])
        keys.remove(1)
        #expect(keys.use(5).isEmpty)
    }
}

/// The installation's models over a real `AddonManager` in a temp folder. Nothing here touches
/// the network.
@MainActor @Suite struct InstallationModelTests {
    let root: URL
    let manager: AddonManager
    let installation: Installation

    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "InstallationModelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let game = root.appending(path: "World of Warcraft/_classic_beta_", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: game.appending(path: "Interface/AddOns"), withIntermediateDirectories: true)
        manager = AddonManager(
            directories: AppDirectories(root: root.appending(path: "AppData")),
            locator: InstallationLocator(baseFolders: [], findApps: { [] }),
            keychain: KeychainStore(service: "ReloadTests-\(UUID().uuidString)"),
            environment: [:]
        )
        installation = try await manager.addInstallation(at: game)
    }

    func addon(_ version: String) -> InstalledAddon {
        InstalledAddon(id: AddonRef(source: .github, identifier: "o/Addon"), name: "Addon", folders: ["Addon"],
                       version: version, releaseID: 1, assetName: "a.zip", publishedAt: .now, installedAt: .now)
    }

    @Test func aFinishedUpdateRebuildsTheInstalledTableOnce() async throws {
        let v1 = addon("v1")
        try await manager.store.modify(installation) { $0 = [v1] }
        let model = InstallationModel(installation: installation, manager: manager, reportError: { _ in })
        await model.installed.reload()
        #expect(model.installed.rows.map(\.id) == [v1.id.description])

        let before = model.installed.installedRowBuilds
        var v2 = addon("v2")
        v2.releaseID = 2
        model.queue.apply(.done(v2))
        #expect(model.installed.installedRowBuilds == before + 1)
        #expect(model.installed.addon(for: v2.id)?.version == "v2")
        #expect(model.installed.updateStates[v2.id] == .upToDate)
    }

    @Test func detailsKeepOnlyTheMostRecentlyViewed() {
        let model = InstallationModel(installation: installation, manager: manager, reportError: { _ in }).inspector
        let refs = (0..<(InspectorModel.detailsLimit + 5)).map { AddonRef(source: .github, identifier: "o/r\($0)") }
        for ref in refs { model.setDetails(.loading, for: ref) }
        #expect(model.details.count == InspectorModel.detailsLimit)
        #expect(model.details[refs[0]] == nil)
        #expect(model.details[refs.last!] != nil)
    }

    /// Installing records the flavors the zip's TOCs ship; the open inspector must show them
    /// like the Browse row does, not the details it loaded before the install.
    @Test func storedAvailabilityPatchesLoadedDetails() {
        let model = InstallationModel(installation: installation, manager: manager, reportError: { _ in })
        let ref = AddonRef(source: .tukui, identifier: "elvui")
        let before = AddonDetails(ref: ref, name: "ElvUI", owner: "Elv", repositoryURL: URL(string: "https://tukui.org")!,
                                  support: .needsDownload, availableFlavors: [.mainline, .vanilla])
        model.inspector.setDetails(.loaded(before, readme: []), for: ref)
        #expect(model.browse.listedRefs.contains(ref))

        model.browse.applyStored([ref: StoredAvailability(support: nil, availableFlavors: [.mainline, .forever, .vanilla])])
        #expect(model.inspector.details[ref]?.details?.availableFlavors == [.mainline, .forever, .vanilla])
        #expect(model.inspector.details[ref]?.details?.support == .needsDownload)
    }
}

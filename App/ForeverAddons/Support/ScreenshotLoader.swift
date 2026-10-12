import CoreGraphics
import Foundation
import ImageIO
import Synchronization

/// Loads README screenshots for the inspector. `AsyncImage` goes through the shared
/// `URLCache`, which is too small to keep images, so every selection re-downloaded them.
/// This keeps the bytes in its own disk cache under the app's Caches folder
/// (`AppDirectories.screenshotsDirectory`) and downsampled images in memory.
actor ScreenshotLoader {
    static let shared = ScreenshotLoader(directory: AppEnvironment.directories().screenshotsDirectory)

    /// Screenshots shown per add-on; READMEs can embed dozens of images.
    static let maxImagesPerAddon = 6
    /// Larger downloads are abandoned: they're animations or print-size art, not screenshots.
    static let maxBytes = 5 * 1024 * 1024
    /// Images decoded at once: enough for a gallery strip, without starving the rest.
    static let maxConcurrentDecodes = 3

    enum Failure: Error { case tooLarge, notAnImage }

    let cache: URLCache
    private let session: URLSession
    private let downloads: CappedDownloads
    private let images = NSCache<NSString, CGImage>()
    private let decodeSlots = DecodeSlots(count: ScreenshotLoader.maxConcurrentDecodes)

    /// - Parameter protocolClasses: test hook for serving responses without the network.
    init(directory: URL, protocolClasses: [AnyClass]? = nil) {
        cache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024, directory: directory)
        let configuration = URLSessionConfiguration.default
        // The loader reads and writes `cache` itself, so a response is kept whatever its
        // cache headers say, and the session doesn't keep a second copy.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        downloads = CappedDownloads(maxBytes: Self.maxBytes)
        session = URLSession(configuration: configuration, delegate: downloads, delegateQueue: nil)
        images.totalCostLimit = 64 * 1024 * 1024
    }

    /// The image at `url`, decoded no larger than `maxPixelSize` on its longer side.
    func image(at url: URL, maxPixelSize: Int) async throws -> CGImage {
        let key = "\(maxPixelSize)|\(url.absoluteString)" as NSString
        if let cached = images.object(forKey: key) { return cached }

        let data = try await bytes(at: url)
        try Task.checkCancellation()
        // Decoding runs off this actor, a few at a time, so a gallery's thumbnails decode
        // in parallel while other loads carry on.
        await decodeSlots.acquire()
        let decoded = await Self.decode(data, maxPixelSize: maxPixelSize)
        await decodeSlots.release()
        guard let cgImage = decoded else { throw Failure.notAnImage }
        images.setObject(cgImage, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return cgImage
    }

    /// The image's bytes: from the disk cache, else downloaded once and stored.
    func bytes(at url: URL) async throws -> Data {
        let request = URLRequest(url: url)
        if let cached = cache.cachedResponse(for: request) { return cached.data }
        let (data, response) = try await downloads.data(for: request, in: session)
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
        return data
    }

    @concurrent
    nonisolated static func decode(_ data: Data, maxPixelSize: Int) async -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A counting semaphore for async work. Waiters are resumed in order.
actor DecodeSlots {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        available = count
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Data tasks that collect the body in the chunks URLSession delivers, refusing anything
/// that says or turns out to be over `maxBytes`, or isn't a raster image. Iterating
/// `AsyncBytes` byte by byte cost about 62 ms of CPU per MB.
nonisolated final class CappedDownloads: NSObject, URLSessionDataDelegate, Sendable {
    private struct Load {
        var data = Data()
        var response: URLResponse?
        let continuation: CheckedContinuation<(Data, URLResponse), any Error>
    }

    let maxBytes: Int
    private let loads = Mutex<[Int: Load]>([:])

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func data(for request: URLRequest, in session: URLSession) async throws -> (Data, URLResponse) {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loads.withLock { $0[task.taskIdentifier] = Load(continuation: continuation) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Why `response` is refused before its body arrives, if it is.
    static func rejection(of response: URLResponse, maxBytes: Int) -> ScreenshotLoader.Failure? {
        if response.expectedContentLength > maxBytes { return .tooLarge }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return .notAnImage }
        if let type = response.mimeType, !type.hasPrefix("image/") || type.contains("svg") { return .notAnImage }
        return nil
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if let failure = Self.rejection(of: response, maxBytes: maxBytes) {
            finish(dataTask.taskIdentifier, with: failure)
            completionHandler(.cancel)
            return
        }
        let expected = Int(max(response.expectedContentLength, 0))
        loads.withLock { loads in
            loads[dataTask.taskIdentifier]?.response = response
            loads[dataTask.taskIdentifier]?.data.reserveCapacity(expected)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let maxBytes = maxBytes
        let tooLarge = loads.withLock { loads -> Bool in
            loads[dataTask.taskIdentifier]?.data.append(data)
            return (loads[dataTask.taskIdentifier]?.data.count ?? 0) > maxBytes
        }
        if tooLarge {
            finish(dataTask.taskIdentifier, with: ScreenshotLoader.Failure.tooLarge)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(task.taskIdentifier, with: error)
    }

    /// Resumes the load once: with its data, or with `error`. Later calls find nothing.
    private func finish(_ id: Int, with error: (any Error)?) {
        guard let load = loads.withLock({ $0.removeValue(forKey: id) }) else { return }
        if let error {
            load.continuation.resume(throwing: error)
        } else if let response = load.response {
            load.continuation.resume(returning: (load.data, response))
        } else {
            load.continuation.resume(throwing: ScreenshotLoader.Failure.notAnImage)
        }
    }
}

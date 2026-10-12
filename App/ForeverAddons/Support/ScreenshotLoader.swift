import CoreGraphics
import Foundation
import ImageIO

/// Loads README screenshots for the inspector. `AsyncImage` goes through the shared
/// `URLCache`, which is too small to keep images, so every selection re-downloaded them.
/// This uses its own session and disk cache, and keeps downsampled images in memory.
actor ScreenshotLoader {
    static let shared = ScreenshotLoader()

    /// Screenshots shown per add-on; READMEs can embed dozens of images.
    static let maxImagesPerAddon = 6
    /// Larger downloads are abandoned: they're animations or print-size art, not screenshots.
    static let maxBytes = 5 * 1024 * 1024

    enum Failure: Error { case tooLarge, notAnImage }

    private let session: URLSession
    private let images = NSCache<NSString, CGImage>()

    init() {
        let configuration = URLSessionConfiguration.default
        let cacheURL = URL.cachesDirectory.appending(path: "Screenshots", directoryHint: .isDirectory)
        configuration.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024,
                                          directory: cacheURL)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
        images.totalCostLimit = 64 * 1024 * 1024
    }

    /// The image at `url`, decoded no larger than `maxPixelSize` on its longer side.
    func image(at url: URL, maxPixelSize: Int) async throws -> CGImage {
        let key = "\(maxPixelSize)|\(url.absoluteString)" as NSString
        if let cached = images.object(forKey: key) { return cached }

        let data = try await download(url)
        try Task.checkCancellation()
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw Failure.notAnImage }
        images.setObject(cgImage, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return cgImage
    }

    private func download(_ url: URL) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        if response.expectedContentLength > Self.maxBytes { throw Failure.tooLarge }
        if let type = response.mimeType, !type.hasPrefix("image/") || type.contains("svg") {
            throw Failure.notAnImage
        }
        var data = Data()
        data.reserveCapacity(max(Int(response.expectedContentLength), 0))
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maxBytes { throw Failure.tooLarge }
        }
        return data
    }
}

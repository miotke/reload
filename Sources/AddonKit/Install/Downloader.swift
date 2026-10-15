import CryptoKit
import Foundation
import Synchronization

/// Moves bytes from a URL to a local file. The default uses `URLSession`; tests inject a stub.
public protocol DownloadTransport: Sendable {
    /// Downloads `url` and moves the result to `destination` (which doesn't exist yet).
    /// Calls `progress` with values in `0...1` as bytes arrive.
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// `URLSession` download tasks with progress from `URLSessionTask.progress`.
public struct URLSessionDownloadTransport: DownloadTransport {
    /// Add-on zips are a few MB; the largest UI suites are tens of MB. Anything past this is
    /// cancelled rather than filling the disk.
    public static let defaultMaxBytes: Int64 = 200 * 1024 * 1024

    public let session: URLSession
    public let maxBytes: Int64

    public init(session: URLSession = URLSessionHTTPClient.sharedSession, maxBytes: Int64 = defaultMaxBytes) {
        self.session = session
        self.maxBytes = maxBytes
    }

    public func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let box = TaskBox(maxBytes: maxBytes)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: request) { location, response, error in
                    box.invalidate()
                    // Progress cancels a large download early; this catches one that finished first.
                    let size = location.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init) ?? 0
                    if box.exceededLimit || size > box.maxBytes || (response?.expectedContentLength ?? 0) > box.maxBytes {
                        continuation.resume(throwing: AddonError.invalidArchive("the download is larger than \(ByteCountFormatter.string(fromByteCount: box.maxBytes, countStyle: .file))"))
                        return
                    }
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        continuation.resume(throwing: AddonError.http(status: http.statusCode, url: url))
                        return
                    }
                    guard let location else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    // `location` is deleted when this handler returns, so move it now.
                    do {
                        try FileManager.default.moveItem(at: location, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.start(task, progress: progress)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Holds the task and its progress observation across the continuation boundary.
    private final class TaskBox: Sendable {
        private struct State {
            var task: URLSessionDownloadTask?
            var observation: NSKeyValueObservation?
            var cancelled = false
            var exceededLimit = false
        }

        let maxBytes: Int64
        private let state = Mutex(State())

        init(maxBytes: Int64) {
            self.maxBytes = maxBytes
        }

        var exceededLimit: Bool { state.withLock { $0.exceededLimit } }

        func start(_ task: URLSessionDownloadTask, progress: @escaping @Sendable (Double) -> Void) {
            // Download progress counts bytes: the declared length, then what has arrived.
            let observation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                if let self, max(p.totalUnitCount, p.completedUnitCount) > self.maxBytes {
                    self.state.withLock { $0.exceededLimit = true }
                    task.cancel()
                    return
                }
                progress(min(max(p.fractionCompleted, 0), 1))
            }
            let cancelled = state.withLock { state in
                state.task = task
                state.observation = observation
                return state.cancelled
            }
            task.resume()
            if cancelled { task.cancel() }
        }

        func cancel() {
            let task = state.withLock { state in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }

        func invalidate() {
            state.withLock { state in
                state.observation?.invalidate()
                state.observation = nil
            }
        }
    }
}

/// Downloads release assets into the cache and keeps the newest few per add-on for
/// offline rollback (docs/features/installing.md).
///
/// Layout: `<caches>/downloads/<source>/<identifier>/<releaseID>-<assetName>`, with the
/// identifier's `/` replaced by `+` and other unsafe characters by `_`.
public actor Downloader {
    public nonisolated let downloadsDirectory: URL
    let transport: any DownloadTransport
    let keepPerAddon: Int
    let maxConcurrent: Int

    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Shared downloads and how many callers are still waiting on each.
    private var inFlight: [URL: (task: Task<URL, Error>, waiters: Int)] = [:]

    /// - Parameters:
    ///   - cachesDirectory: The app's caches folder (`AppDirectories.caches`).
    ///   - keepPerAddon: Archives kept per add-on after a download (at least 1).
    ///   - maxConcurrent: Downloads allowed at once (docs/features/installing.md says 4).
    public init(
        cachesDirectory: URL,
        transport: any DownloadTransport = URLSessionDownloadTransport(),
        keepPerAddon: Int = 2,
        maxConcurrent: Int = 4
    ) {
        self.downloadsDirectory = cachesDirectory.appending(path: "downloads", directoryHint: .isDirectory)
        self.transport = transport
        self.keepPerAddon = max(1, keepPerAddon)
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Returns the cached archive for `release`, downloading it if needed, then prunes
    /// older archives of the same add-on.
    public func download(_ release: ResolvedRelease, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let destination = archiveURL(for: release)
        if Self.isUsableFile(destination) {
            touch(destination)
            progress(1)
            return destination
        }
        let task: Task<URL, Error>
        let joined = inFlight[destination] != nil
        if let existing = inFlight[destination] {
            task = existing.task
            inFlight[destination]?.waiters += 1
        } else {
            let throttled = Self.throttle(progress)
            task = Task {
                defer { self.inFlight[destination] = nil }
                let url = try await self.fetch(release, to: destination, progress: throttled)
                self.prune(directory: destination.deletingLastPathComponent(), keeping: destination)
                return url
            }
            inFlight[destination] = (task, 1)
        }
        // One caller giving up mustn't cancel a download others still wait for.
        let url = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.waiterCancelled(destination) }
        }
        try Task.checkCancellation()
        // The download reported its own progress to the caller that started it.
        if joined { progress(1) }
        return url
    }

    private func waiterCancelled(_ destination: URL) {
        guard var entry = inFlight[destination] else { return }
        entry.waiters -= 1
        inFlight[destination] = entry
        if entry.waiters <= 0 { entry.task.cancel() }
    }

    /// Passes on progress only when it moved by 1% and 100 ms passed (or it's done), so a
    /// fast download doesn't flood the UI with events.
    static func throttle(_ progress: @escaping @Sendable (Double) -> Void) -> @Sendable (Double) -> Void {
        let last = Mutex((value: -1.0, at: ContinuousClock.Instant.now - .seconds(1)))
        return { value in
            let send = last.withLock { state -> Bool in
                let now = ContinuousClock.now
                guard value >= 1 || (value - state.value >= 0.01 && now - state.at >= .milliseconds(100)) else { return false }
                state = (value, now)
                return true
            }
            if send { progress(value) }
        }
    }

    private func fetch(_ release: ResolvedRelease, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        await acquireSlot()
        defer { releaseSlot() }
        try Task.checkCancellation()

        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appending(path: ".partial-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: partial) }

        try await transport.download(from: release.downloadURL, to: partial, progress: progress)
        guard Self.isUsableFile(partial) else {
            throw AddonError.invalidArchive("download of \(release.assetName) is empty")
        }
        // A corrupted or tampered file never reaches the cache, so it's never installed.
        if let expected = release.md5, try await Self.md5(of: partial) != expected {
            throw AddonError.invalidArchive("\(release.assetName) doesn't match the checksum its host published")
        }
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: partial, to: destination)
        touch(destination)
        progress(1)
        return destination
    }

    /// Lower-case hex MD5 of the file at `url`, read in 1 MB chunks off this actor.
    @concurrent
    static func md5(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Cached archives for `ref`, newest first. Use for rollback.
    public func cachedArchives(for ref: AddonRef) -> [URL] {
        Self.archives(in: addonDirectory(for: ref))
    }

    /// Where `release`'s archive is (or will be) cached.
    public nonisolated func archiveURL(for release: ResolvedRelease) -> URL {
        let name = Self.sanitize("\(release.releaseID)-\(release.assetName)")
        return addonDirectory(for: release.ref).appending(path: name, directoryHint: .notDirectory)
    }

    nonisolated func addonDirectory(for ref: AddonRef) -> URL {
        downloadsDirectory
            .appending(path: ref.source.rawValue, directoryHint: .isDirectory)
            .appending(path: Self.sanitize(ref.identifier.replacingOccurrences(of: "/", with: "+")), directoryHint: .isDirectory)
    }

    // MARK: - Cache maintenance

    private func prune(directory: URL, keeping current: URL) {
        let others = Self.archives(in: directory).filter { $0.lastPathComponent != current.lastPathComponent }
        for url in others.dropFirst(keepPerAddon - 1) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Marks `url` as most recently used so pruning keeps it.
    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path(percentEncoded: false))
    }

    static func archives(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        let dated: [(URL, Date)] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        return dated
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent > $1.0.lastPathComponent }
            .map(\.0)
    }

    static func isUsableFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0
    }

    /// One safe path component: `[A-Za-z0-9._+-]` only, never hidden or empty.
    static func sanitize(_ component: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        var result = String(component.map { allowed.contains($0) ? $0 : "_" })
        while result.hasPrefix(".") { result = "_" + result.dropFirst() }
        return result.isEmpty ? "_" : result
    }

    // MARK: - Concurrency limit

    private func acquireSlot() async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            active -= 1
        } else {
            // Hand the slot straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }
}

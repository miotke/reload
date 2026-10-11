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
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: request) { location, response, error in
                    box.invalidate()
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
        }

        private let state = Mutex(State())

        func start(_ task: URLSessionDownloadTask, progress: @escaping @Sendable (Double) -> Void) {
            let observation = task.progress.observe(\.fractionCompleted) { p, _ in
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
/// offline rollback (DESIGN.md §6.7).
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
    private var inFlight: [URL: Task<URL, Error>] = [:]

    /// - Parameters:
    ///   - cachesDirectory: The app's caches folder (`AppDirectories.caches`).
    ///   - keepPerAddon: Archives kept per add-on after a download (at least 1).
    ///   - maxConcurrent: Downloads allowed at once (DESIGN.md §6.7 says 4).
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
        if let existing = inFlight[destination] {
            let url = try await existing.value
            progress(1)
            return url
        }

        let task = Task { try await self.fetch(release, to: destination, progress: progress) }
        inFlight[destination] = task
        defer { inFlight[destination] = nil }
        let url = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        prune(directory: destination.deletingLastPathComponent(), keeping: destination)
        return url
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
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: partial, to: destination)
        touch(destination)
        progress(1)
        return destination
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

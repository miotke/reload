import Foundation

/// Calls `onChange` (debounced) when entries in a directory are added, removed or replaced.
///
/// Used to watch `InstallStore.storeDirectory`, so add-ons changed by `addonctl` show up
/// live (DESIGN.md §9.1). The store writes atomically (write to a temp file, then rename),
/// which shows up as a write to the directory itself. Creates the directory if it's missing
/// and re-opens it if it's deleted or moved.
nonisolated final class DirectoryWatcher: @unchecked Sendable {
    // All mutable state is only touched on `queue`.
    private let url: URL
    private let latency: DispatchTimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.andrewmiotke.ForeverAddons.DirectoryWatcher")
    private var source: (any DispatchSourceFileSystemObject)?
    private var pending: DispatchWorkItem?
    private var stopped = false

    init(url: URL, latency: DispatchTimeInterval = .milliseconds(400), onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.latency = latency
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
        pending?.cancel()
    }

    func start() {
        queue.async { self.open() }
    }

    func stop() {
        queue.sync {
            stopped = true
            pending?.cancel()
            pending = nil
            source?.cancel()
            source = nil
        }
    }

    private func open() {
        guard !stopped, source == nil else { return }
        let path = url.path(percentEncoded: false)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let descriptor = Darwin.open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .link], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                // The directory itself went away; watch the new one at the same path.
                self.source?.cancel()
                self.source = nil
                self.queue.asyncAfter(deadline: .now() + self.latency) { self.open() }
            }
            self.scheduleChange()
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    private func scheduleChange() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.onChange()
        }
        pending = item
        queue.asyncAfter(deadline: .now() + latency, execute: item)
    }
}

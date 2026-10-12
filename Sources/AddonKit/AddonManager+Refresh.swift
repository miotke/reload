import Foundation
import Synchronization

/// Background refresh (docs/search.md#refresh): catalogue, installed add-ons' update
/// states, and support verdicts for the repos that need them.
extension AddonManager {
    /// Without `force`, a refresh this soon after the last one finishes at once with the
    /// stored update states.
    public static let refreshInterval: TimeInterval = 2 * 60 * 60
    /// The first refresh checks this many of the most recently updated catalogue repos
    /// that ship a release.json.
    public static let seedCount = 200
    /// Each refresh also re-checks this many of the oldest verdicts.
    public static let rotationCount = 20
    /// Verdicts older than this are eligible for the rotation.
    public static let rotationAge: TimeInterval = 14 * 24 * 60 * 60
    /// Support checks in flight at once (github.com, not the API).
    public static let refreshConcurrency = 4
    /// Progress is emitted at most this often, apart from phase changes and the end.
    static let progressInterval: Duration = .milliseconds(100)
    /// Verdicts are written in batches of this many.
    static let supportBatchSize = 25

    public nonisolated func refresh(in installation: Installation, force: Bool) -> AsyncStream<RefreshProgress> {
        // Only the newest progress matters; `.finished` is always the last element, so it's
        // never the one dropped.
        let (stream, continuation) = AsyncStream.makeStream(of: RefreshProgress.self, bufferingPolicy: .bufferingNewest(8))
        let task = Task {
            await self.performRefresh(installation, force: force, continuation: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func lastRefresh(in installation: Installation) async -> Date? {
        try? await database.query("SELECT last_refresh_at FROM refresh_state WHERE installation_id = ?", installation.id).first?.date(0)
    }

    private func performRefresh(_ installation: Installation, force: Bool, continuation: AsyncStream<RefreshProgress>.Continuation) async {
        let last = await lastRefresh(in: installation)
        if !force, let last, now().timeIntervalSince(last) < Self.refreshInterval {
            let updates = await storedUpdates(in: installation)
            continuation.yield(RefreshProgress(phase: .finished, completed: 1, total: 1, message: "Up to date", updates: updates))
            return
        }
        let firstRefresh = last == nil
        let reporter = ProgressReporter(continuation: continuation, interval: Self.progressInterval)

        // 1. Catalogue: revalidated when older than 24 h, or now when forced.
        reporter.send(RefreshProgress(phase: .catalogue, completed: 0, total: 1, message: "Downloading the add-on catalogue…"), force: true)
        let diff = (try? await catalogue.refresh(force: force)) ?? CatalogueDiff()
        reporter.send(RefreshProgress(phase: .catalogue, completed: 1, total: 1, message: "Catalogue ready"), force: true)
        guard !Task.isCancelled else { return }

        // 2. Installed add-ons.
        let installed = (try? await store.addons(in: installation)) ?? []
        reporter.send(RefreshProgress(phase: .updates, completed: 0, total: installed.count, message: "Checking for updates…"), force: true)
        let total = installed.count
        let updates = (try? await checkForUpdates(in: installation, background: true) { addon, done in
            reporter.send(RefreshProgress(phase: .updates, completed: done, total: total, message: "Checked \(addon.name)"))
        }) ?? [:]
        guard !Task.isCancelled else { return }

        // 3. Support verdicts.
        let targets = await supportTargets(installation: installation, installed: installed.map(\.id), diff: diff, seed: firstRefresh)
        reporter.send(RefreshProgress(phase: .support, completed: 0, total: targets.count, message: "Checking Forever support…"), force: true)
        await checkSupport(targets, flavor: installation.flavor, reporter: reporter)
        guard !Task.isCancelled else { return }

        // 4. Done.
        let finished = now()
        _ = try? await database.execute("""
            INSERT INTO refresh_state(installation_id, last_refresh_at, updates_json) VALUES (?, ?, ?)
            ON CONFLICT(installation_id) DO UPDATE SET last_refresh_at = excluded.last_refresh_at, updates_json = excluded.updates_json
            """, installation.id, finished, StoredUpdateState.encode(updates))
        await database.notify(["refresh_state"])
        continuation.yield(RefreshProgress(phase: .finished, completed: targets.count, total: targets.count, message: "Done", updates: updates))
    }

    /// Repos to check, most useful first:
    /// - installed add-ons without a fresh verdict;
    /// - on the first refresh, the `seedCount` most recently updated catalogue repos with a
    ///   release.json;
    /// - repos whose catalogue `last_updated` is newer than their verdict, and repos new to
    ///   the catalogue (with a release.json);
    /// - the `rotationCount` oldest verdicts past `rotationAge`.
    /// Repos without a release.json aren't checked: search shows them as `.needsDownload`.
    func supportTargets(installation: Installation, installed: [AddonRef], diff: CatalogueDiff, seed: Bool) async -> [AddonRef] {
        let flavor = installation.flavor.rawValue
        var names: [String] = []
        for ref in installed where !(await supportCache.isFresh(ref, flavor: installation.flavor)) {
            names.append(ref.identifier)
        }
        if seed {
            let rows = (try? await database.query("""
                SELECT c.full_name FROM catalogue c
                LEFT JOIN support s ON s.full_name = c.full_name AND s.flavor = ?
                WHERE c.has_release_json = 1 AND c.source = 'catalogue' AND (s.checked_at IS NULL OR s.checked_at < ?)
                ORDER BY c.last_updated DESC LIMIT ?
                """, flavor, now().addingTimeInterval(-SupportCache.defaultTTL), Self.seedCount)) ?? []
            names += rows.compactMap { $0.string(0) }
        }
        let changed = (try? await database.query("""
            SELECT c.full_name FROM catalogue c JOIN support s ON s.full_name = c.full_name AND s.flavor = ?
            WHERE c.has_release_json = 1 AND c.last_updated > s.checked_at
            ORDER BY c.last_updated DESC
            """, flavor)) ?? []
        names += changed.compactMap { $0.string(0) }
        if !seed, !diff.changed.isEmpty {
            let stored = Set((await supportCache.statuses(flavor: installation.flavor)).keys.map { $0.identifier.lowercased() })
            for name in diff.changed.sorted() where !stored.contains(name.lowercased()) {
                if let entry = await catalogue.entry(for: AddonRef(source: .github, identifier: name)), entry.hasReleaseJSON {
                    names.append(entry.fullName)
                }
            }
        }
        let rotation = (try? await database.query("""
            SELECT full_name FROM support WHERE flavor = ? AND checked_at < ? ORDER BY checked_at LIMIT ?
            """, flavor, now().addingTimeInterval(-Self.rotationAge), Self.rotationCount)) ?? []
        names += rotation.compactMap { $0.string(0) }

        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }.map { AddonRef(source: .github, identifier: $0) }
    }

    private func checkSupport(_ targets: [AddonRef], flavor: Flavor, reporter: ProgressReporter) async {
        let github = self.github
        var pending: [SupportRecord] = []
        var lastFlush = ContinuousClock.now
        var done = 0
        await withTaskGroup(of: (AddonRef, SupportCheck).self) { group in
            var queue = targets[...]
            func addNext() {
                guard let ref = queue.popFirst() else { return }
                group.addTask { (ref, await github.check(ref, flavor: flavor, background: true, reuse: false)) }
            }
            for _ in 0..<Self.refreshConcurrency { addNext() }
            while let (ref, check) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                done += 1
                pending.append(SupportRecord(ref: ref, status: check.status, tag: check.tag, checkedAt: now()))
                // Batched so the database (and anyone watching it) sees a few commits, not hundreds.
                if pending.count >= Self.supportBatchSize || ContinuousClock.now - lastFlush > .seconds(1) {
                    await supportCache.set(pending, flavor: flavor)
                    pending = []
                    lastFlush = .now
                }
                let name = ref.identifier.split(separator: "/").last.map(String.init) ?? ref.identifier
                reporter.send(RefreshProgress(phase: .support, completed: done, total: targets.count, message: "Checked \(name)"))
                addNext()
            }
        }
        await supportCache.set(pending, flavor: flavor)
    }

    /// The last refresh's update states, corrected for anything installed since.
    private func storedUpdates(in installation: Installation) async -> [AddonRef: UpdateState] {
        guard let json = try? await database.query(
            "SELECT updates_json FROM refresh_state WHERE installation_id = ?", installation.id).first?.string(0) else { return [:] }
        let stored = StoredUpdateState.decode(json)
        let installed = Dictionary(((try? await store.addons(in: installation)) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [AddonRef: UpdateState] = [:]
        for (ref, state) in stored {
            guard let addon = installed[ref] else { continue }
            if case .available(let release) = state, !addon.isUpdate(release) {
                out[ref] = .upToDate
            } else if addon.pinned {
                out[ref] = .pinned
            } else {
                out[ref] = state
            }
        }
        return out
    }
}

/// Coalesces refresh progress to about 10 Hz. Phase changes and the end always go through.
final class ProgressReporter: Sendable {
    let continuation: AsyncStream<RefreshProgress>.Continuation
    let interval: Duration
    private let lastSent = Mutex(ContinuousClock.now - .seconds(1))

    init(continuation: AsyncStream<RefreshProgress>.Continuation, interval: Duration) {
        self.continuation = continuation
        self.interval = interval
    }

    func send(_ progress: RefreshProgress, force: Bool = false) {
        let pass = lastSent.withLock { last -> Bool in
            let now = ContinuousClock.now
            guard force || progress.completed == progress.total || now - last >= interval else { return false }
            last = now
            return true
        }
        if pass { continuation.yield(progress) }
    }
}

/// `UpdateState` as stored in `refresh_state.updates_json`.
struct StoredUpdateState: Codable {
    struct Release: Codable {
        var name: String
        var version: String
        var releaseID: Int64
        var publishedAt: Date
        var downloadURL: URL
        var assetName: String
        var changelog: String?
        var isPrerelease: Bool
    }

    var ref: AddonRef
    var kind: String
    var message: String?
    var release: Release?

    static func encode(_ states: [AddonRef: UpdateState]) -> String {
        let rows = states.map { ref, state -> StoredUpdateState in
            switch state {
            case .upToDate: StoredUpdateState(ref: ref, kind: "upToDate")
            case .pinned: StoredUpdateState(ref: ref, kind: "pinned")
            case .noCompatibleRelease: StoredUpdateState(ref: ref, kind: "noCompatibleRelease")
            case .failed(let message): StoredUpdateState(ref: ref, kind: "failed", message: message)
            case .available(let r):
                StoredUpdateState(ref: ref, kind: "available", release: Release(
                    name: r.name, version: r.version, releaseID: r.releaseID, publishedAt: r.publishedAt,
                    downloadURL: r.downloadURL, assetName: r.assetName, changelog: r.changelog, isPrerelease: r.isPrerelease))
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(rows)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    static func decode(_ json: String) -> [AddonRef: UpdateState] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let rows = try? decoder.decode([StoredUpdateState].self, from: Data(json.utf8)) else { return [:] }
        var out: [AddonRef: UpdateState] = [:]
        for row in rows {
            switch row.kind {
            case "upToDate": out[row.ref] = .upToDate
            case "pinned": out[row.ref] = .pinned
            case "noCompatibleRelease": out[row.ref] = .noCompatibleRelease
            case "failed": out[row.ref] = .failed(row.message ?? "")
            case "available":
                guard let r = row.release else { continue }
                out[row.ref] = .available(ResolvedRelease(
                    ref: row.ref, name: r.name, version: r.version, releaseID: r.releaseID, publishedAt: r.publishedAt,
                    downloadURL: r.downloadURL, assetName: r.assetName, changelog: r.changelog, isPrerelease: r.isPrerelease))
            default: continue
            }
        }
        return out
    }
}

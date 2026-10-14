import Foundation
import Synchronization

/// Background refresh (docs/features/refresh.md): catalogue, installed add-ons' update
/// states, and support verdicts for the repos that need them.
extension AddonManager {
    /// Without `force`, a refresh this soon after the last one finishes at once with the
    /// stored update states.
    public static let refreshInterval: TimeInterval = 2 * 60 * 60
    /// The first refresh checks this many of the most recently updated catalogue repos
    /// that ship a release.json.
    public static let seedCount = 200
    /// The first refresh of a later installation seeds fewer: Browse already has verdicts for
    /// the first one, and latest tags are shared between flavors.
    public static let laterSeedCount = 100
    /// Each refresh also re-checks this many of the oldest verdicts.
    public static let rotationCount = 20
    /// Verdicts older than this are eligible for the rotation.
    public static let rotationAge: TimeInterval = 14 * 24 * 60 * 60
    /// Support checks in flight at once (github.com, not the API).
    public static let refreshConcurrency = 4
    /// Progress is emitted at most this often, apart from phase changes and the end.
    static let progressInterval: Duration = .milliseconds(100)

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
        // Sources that are off download nothing (docs/features/sources.md).
        let enabled = await database.enabledSources()
        let diff = enabled.contains(.github) ? (try? await catalogue.refresh(force: force)) ?? CatalogueDiff() : CatalogueDiff()
        await refreshHostedListings(force: force)
        reporter.send(RefreshProgress(phase: .catalogue, completed: 1, total: 1, message: "Catalogue ready"), force: true)
        guard !Task.isCancelled else { return }

        // 2. Installed add-ons.
        let installed = (try? await store.addons(in: installation)) ?? []
        reporter.send(RefreshProgress(phase: .updates, completed: 0, total: installed.count, message: "Checking for updates…"), force: true)
        let total = installed.count
        // A forced refresh (⌘R) asks for every installed add-on's latest tag; the background
        // one reuses answers younger than their TTL. Either way the answers are stored, so
        // the support phase below reuses them for installed add-ons.
        let policy: CachePolicy = force ? .forceRevalidate : .revalidateIfStale
        let updates = (try? await checkForUpdates(in: installation, policy: policy, background: true) { addon, done in
            reporter.send(RefreshProgress(phase: .updates, completed: done, total: total, message: "Checked \(addon.name)"))
        }) ?? [:]
        guard !Task.isCancelled else { return }

        // 3. Support verdicts.
        // With GitHub off, only installed GitHub add-ons are checked.
        let targets = enabled.contains(.github)
            ? await supportTargets(installation: installation, installed: installed.map(\.id), diff: diff, seed: firstRefresh)
            : installed.map(\.id).filter { $0.source == .github }
        reporter.send(RefreshProgress(phase: .support, completed: 0, total: targets.count, message: "Checking \(installation.flavor.displayName) support…"), force: true)
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
    /// - installed add-ons (`check` skips those with fresh answers);
    /// - on the first refresh, the `seedCount` most recently updated catalogue repos with a
    ///   release.json (`laterSeedCount` once another installation has been refreshed);
    /// - repos whose catalogue `last_updated` is newer than their verdict, and repos new to
    ///   the catalogue (with a release.json);
    /// - the `rotationCount` oldest verdicts past `rotationAge`.
    /// Repos without a release.json aren't checked: search shows them as `.needsDownload`.
    func supportTargets(installation: Installation, installed: [AddonRef], diff: CatalogueDiff, seed: Bool) async -> [AddonRef] {
        let flavor = installation.flavor.rawValue
        var names: [String] = []
        // Installed add-ons are always targets; `check` decides whether that needs a request.
        // Hosted add-ons have no verdicts to check: their updates come from `checkForUpdates`.
        names += installed.filter { $0.source == .github }.map(\.identifier)
        if seed {
            let seededBefore = (try? await database.query(
                "SELECT count(*) FROM refresh_state WHERE installation_id != ? AND last_refresh_at IS NOT NULL", installation.id
            ).first?.int(0)).flatMap { $0 } ?? 0
            let rows = (try? await database.query("""
                SELECT c.full_name FROM catalogue c
                LEFT JOIN support s ON s.full_name = c.full_name AND s.flavor = ?
                WHERE c.has_release_json = 1 AND c.source = 'catalogue' AND (s.checked_at IS NULL OR s.checked_at < ?)
                ORDER BY c.last_updated DESC LIMIT ?
                """, flavor, now().addingTimeInterval(-SupportCache.defaultTTL), seededBefore > 0 ? Self.laterSeedCount : Self.seedCount)) ?? []
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

    /// Runs `check` for each target, 4 at a time. `check` owns the stored verdicts: it skips
    /// the network for answers still within their TTL and writes what it learns.
    private func checkSupport(_ targets: [AddonRef], flavor: Flavor, reporter: ProgressReporter) async {
        let latest = github.latest
        var done = 0
        await withTaskGroup(of: AddonRef.self) { group in
            var queue = targets[...]
            func addNext() {
                guard let ref = queue.popFirst() else { return }
                group.addTask {
                    _ = await latest.check(ref, flavor: flavor, policy: .revalidateIfStale, background: true)
                    return ref
                }
            }
            for _ in 0..<Self.refreshConcurrency { addNext() }
            while let ref = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                done += 1
                let name = ref.identifier.split(separator: "/").last.map(String.init) ?? ref.identifier
                reporter.send(RefreshProgress(phase: .support, completed: done, total: targets.count, message: "Checked \(name)"))
                addNext()
            }
        }
    }


    /// The last refresh's update states, corrected for anything installed since.
    func storedUpdates(in installation: Installation) async -> [AddonRef: UpdateState] {
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
        var flavorBuild: Flavor?
    }

    var ref: AddonRef
    var kind: String
    var message: String?
    var release: Release?

    static func encode(_ states: [AddonRef: UpdateState]) -> String {
        // Sorted, so unchanged states encode identically and the store write is skipped.
        let rows = states.sorted { $0.key.description < $1.key.description }.map { ref, state -> StoredUpdateState in
            switch state {
            case .upToDate: StoredUpdateState(ref: ref, kind: "upToDate")
            case .pinned: StoredUpdateState(ref: ref, kind: "pinned")
            case .noCompatibleRelease: StoredUpdateState(ref: ref, kind: "noCompatibleRelease")
            case .failed(let message): StoredUpdateState(ref: ref, kind: "failed", message: message)
            case .available(let r):
                StoredUpdateState(ref: ref, kind: "available", release: Release(
                    name: r.name, version: r.version, releaseID: r.releaseID, publishedAt: r.publishedAt,
                    downloadURL: r.downloadURL, assetName: r.assetName, changelog: r.changelog, isPrerelease: r.isPrerelease,
                    flavorBuild: r.flavorBuild))
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
                    downloadURL: r.downloadURL, assetName: r.assetName, changelog: r.changelog, isPrerelease: r.isPrerelease,
                    flavorBuild: r.flavorBuild))
            default: continue
            }
        }
        return out
    }
}

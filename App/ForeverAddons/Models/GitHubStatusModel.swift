import AddonKit
import Foundation
import Observation

/// Settings ▸ GitHub's rate-limit rows: the core's `gitHubStatus()`, re-read while the tab
/// is visible. The values are the core's; this only decides when to ask again.
@Observable @MainActor
final class GitHubStatusModel {
    /// Nil until the first load.
    private(set) var status: GitHubStatus?
    /// When `status` was read, so relative times stay put between reloads.
    private(set) var now = Date.now
    @ObservationIgnored private var lastLoad: ContinuousClock.Instant?

    static let interval: Duration = .seconds(30)
    /// Metadata commits come in bursts during a refresh; one reload per this is plenty.
    static let changeThrottle: Duration = .seconds(2)

    var display: GitHubStatusDisplay {
        GitHubStatusDisplay(status: status ?? GitHubStatus(), now: now)
    }

    func refresh(from manager: any AddonManaging) async {
        lastLoad = .now
        let status = await manager.gitHubStatus()
        show(status, now: .now)
    }

    /// Reloads every `interval`, and after the app's own metadata writes (which usually
    /// follow a request), until cancelled. Run from the tab's `.task`.
    func watch(_ manager: any AddonManaging) async {
        let changes = manager.metadataChanges()
        let listener = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                // The interval loop picks up whatever a skipped change wrote.
                if let lastLoad, lastLoad.duration(to: .now) < Self.changeThrottle { continue }
                await refresh(from: manager)
            }
        }
        defer { listener.cancel() }
        while !Task.isCancelled {
            await refresh(from: manager)
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// Sets the displayed state without a manager (snapshots).
    func show(_ status: GitHubStatus, now: Date) {
        self.status = status
        self.now = now
    }
}

/// One quota row: "42 of 60 left", how full, and when it resets.
struct GitHubQuotaDisplay: Equatable {
    var value: String
    /// 0...1 remaining, nil when unknown.
    var fraction: Double?
    var detail: String
    var isExhausted = false
}

/// `GitHubStatus` as Settings shows it, at a given `now`.
struct GitHubStatusDisplay: Equatable {
    var api: GitHubQuotaDisplay
    var search: GitHubQuotaDisplay
    /// Set while github.com's quota-free requests are paused.
    var pauseWarning: String?

    init(status: GitHubStatus, now: Date) {
        // GitHub's documented limits; the core reports `apiLimit` once it knows it.
        let apiLimit = status.apiLimit ?? (status.hasToken ? 5_000 : 60)
        let searchLimit = status.hasToken ? 30 : 10
        api = Self.quota(status.api, limit: apiLimit, per: "an hour", now: now)
        search = Self.quota(status.search, limit: searchLimit, per: "a minute", now: now)
        if let until = status.webPausedUntil, until > now {
            pauseWarning = "github.com asked us to slow down — resumes in \(Self.duration(from: now, to: until))."
        }
    }

    static func quota(_ state: RateLimitState?, limit: Int, per window: String, now: Date) -> GitHubQuotaDisplay {
        let perWindow = "\(limit.formatted()) \(window)"
        guard let remaining = state?.remaining else {
            return GitHubQuotaDisplay(value: "Not used yet", fraction: nil, detail: perWindow)
        }
        guard let resetAt = state?.resetAt else {
            return GitHubQuotaDisplay(value: left(remaining, of: limit), fraction: fraction(remaining, of: limit), detail: perWindow)
        }
        // A past reset means GitHub has refilled the window since it last reported.
        guard resetAt > now else {
            return GitHubQuotaDisplay(value: left(limit, of: limit), fraction: 1, detail: perWindow)
        }
        let resetsIn = duration(from: now, to: resetAt)
        if remaining == 0 {
            return GitHubQuotaDisplay(value: left(0, of: limit), fraction: 0, detail: "Used up, resets in \(resetsIn)", isExhausted: true)
        }
        return GitHubQuotaDisplay(value: left(remaining, of: limit), fraction: fraction(remaining, of: limit), detail: "Resets in \(resetsIn)")
    }

    /// "under a minute", "23 min", "1 hr 5 min", rounding up so it never says 0.
    static func duration(from now: Date, to date: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds >= 60 else { return "under a minute" }
        let minutes = Int((seconds / 60).rounded(.up))
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    private static func left(_ remaining: Int, of limit: Int) -> String {
        "\(remaining.formatted()) of \(limit.formatted()) left"
    }

    private static func fraction(_ remaining: Int, of limit: Int) -> Double {
        limit > 0 ? min(max(Double(remaining) / Double(limit), 0), 1) : 0
    }
}

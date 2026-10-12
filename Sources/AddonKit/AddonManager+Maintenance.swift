import Foundation

/// Diagnostics and cache clearing for `addonctl doctor` and `cache` (docs/cli/maintenance.md),
/// and the GitHub status the app's settings show (docs/network/budget.md).
extension AddonManager {
    /// Remaining GitHub API calls and when the limit resets, as last reported by GitHub.
    public func rateLimit() async -> (remaining: Int?, resetAt: Date?) {
        let api = await gitHubStatus().api
        return (api?.remaining, api?.resetAt)
    }

    /// Search calls a minute without and with a token.
    static let searchLimits = (anonymous: 10, authenticated: 30)

    /// From memory and the database only; never makes a request. A window whose reset has
    /// passed is reported as full, since GitHub has refilled it.
    public func gitHubStatus() async -> GitHubStatus {
        let date = now()
        let hasToken = await github.api.hasToken()
        let apiLimit = await github.api.quotaLimit()
        // The client reads the stored `core` row on first use; after a token change it
        // reports nothing until GitHub answers for the new account.
        let core = await github.api.rateLimit()
        let api = core.remaining == nil && core.resetAt == nil ? nil : RateLimitState(remaining: core.remaining, resetAt: core.resetAt)
        let searchLimit = hasToken ? Self.searchLimits.authenticated : Self.searchLimits.anonymous
        return GitHubStatus(
            api: Self.current(api, limit: apiLimit, at: date),
            search: Self.current(await database.rateLimit("search"), limit: searchLimit, at: date),
            apiLimit: apiLimit,
            hasToken: hasToken,
            webPausedUntil: await github.web.pausedUntil()
        )
    }

    static func current(_ state: RateLimitState?, limit: Int, at date: Date) -> RateLimitState? {
        guard let state else { return nil }
        if let reset = state.resetAt, reset <= date { return RateLimitState(remaining: limit, resetAt: nil) }
        return state
    }

    /// Deletes downloaded archives, the catalogue cache and cached support checks.
    public func clearCaches() async throws {
        await supportCache.removeAll()
        let fm = FileManager.default
        if fm.fileExists(atPath: directories.caches.path(percentEncoded: false)) {
            for item in try fm.contentsOfDirectory(at: directories.caches, includingPropertiesForKeys: nil) {
                try fm.removeItem(at: item)
            }
        }
    }
}

import Foundation

/// Diagnostics and cache clearing for `addonctl doctor` and `cache` (docs/cli/maintenance.md).
extension AddonManager {
    /// Remaining GitHub API calls and when the limit resets, as last reported by GitHub.
    public func rateLimit() async -> (remaining: Int?, resetAt: Date?) {
        await github.api.rateLimit()
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

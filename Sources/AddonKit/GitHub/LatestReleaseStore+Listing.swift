import Foundation

/// The release listing of repos that publish several streams (docs/features/optional-parts.md#the-release-listing).
/// `LatestReleaseStore` owns it like the latest tags it's checked against: callers pass a
/// `CachePolicy`, and this decides whether to spend API calls.
extension LatestReleaseStore {
    /// Pages of `GitHubAPIClient.listingPageSize` releases read per listing: 300 releases,
    /// enough to reach a stream whose last release is far behind busier ones.
    static let maxListingPages = 3

    /// The repo's stored stream listing, revalidated as `policy` allows:
    /// - `.preferStored`: what's stored, never a request.
    /// - otherwise the listing is current while the repo's latest stable tag (quota-free,
    ///   `latestRelease` under the same policy) is the one it was fetched with, so an unchanged
    ///   repo costs no API call. A failure is retried after 15 minutes, a missing repo after
    ///   24 hours. When github.com doesn't answer, `.revalidateIfStale` keeps a listing under
    ///   6 hours old.
    /// - a fetch sends page 1's ETag (a 304 keeps the stored releases), else reads up to
    ///   `maxListingPages` pages. With `keepReserve` (inspector, background) no call is made
    ///   within `GitHubAPIClient.supportReserve` of the limit, so installs and updates keep it.
    ///
    /// Concurrent callers for one repo share one fetch. Throws only when nothing is stored
    /// and the fetch failed.
    func listing(
        for ref: AddonRef, flavor: Flavor, policy: CachePolicy, background: Bool = false, keepReserve: Bool = false
    ) async throws -> ReleaseListing? {
        let repo = ref.repo
        guard repo.source == .github, (try? GitHubReleaseResolver.split(repo)) != nil else { return nil }
        if policy == .preferStored { return await store.storedListing(for: repo) }
        // The decision and the fetch are shared, so callers that start together (an add-on
        // and its parts in one update check) can't each see the old listing and fetch.
        let key = "\(GitHubReleaseResolver.cacheKey(repo))|\(policy)|\(background)|\(keepReserve)"
        let task: Task<ReleaseListing?, any Error>
        if let running = inFlightListings[key] {
            task = running
        } else {
            task = Task {
                defer { self.inFlightListings[key] = nil }
                return try await self.revalidatedListing(repo, flavor: flavor, policy: policy, background: background, keepReserve: keepReserve)
            }
            inFlightListings[key] = task
        }
        return try await task.value
    }

    private func revalidatedListing(
        _ repo: AddonRef, flavor: Flavor, policy: CachePolicy, background: Bool, keepReserve: Bool
    ) async throws -> ReleaseListing? {
        let (owner, name) = try GitHubReleaseResolver.split(repo)
        let stored = await store.storedListing(for: repo)
        let date = now()
        if let stored {
            if let failed = stored.failedAt, date.timeIntervalSince(failed) < SupportCache.errorTTL { return stored }
            if stored.notFound, date.timeIntervalSince(stored.checkedAt) < SupportCache.negativeTTL { return stored }
        }
        let latest = await latestRelease(for: repo, flavor: flavor, policy: policy, background: background)
        let known = !latest.failed && latest.status != .unknown
        // A listing that failed or 404'd more than its TTL ago is fetched again either way.
        if let stored, stored.failedAt == nil, !stored.notFound {
            let current = known
                ? latest.tag == stored.latestTag
                : policy == .revalidateIfStale && date.timeIntervalSince(stored.checkedAt) < SupportCache.apiCheckInterval
            if current { return stored }
        }
        return try await fetchListing(repo, owner: owner, name: name, stored: stored, latestTag: known ? latest.tag : nil, keepReserve: keepReserve)
    }

    /// - Parameter latestTag: the repo's latest stable tag now, which the new listing is current against.
    private func fetchListing(
        _ repo: AddonRef, owner: String, name: String, stored: ReleaseListing?, latestTag: String?, keepReserve: Bool
    ) async throws -> ReleaseListing? {
        if keepReserve, await api.isWithinSupportReserve() { return stored }
        do {
            var releases: [GitHubRelease]
            let etag: String?
            switch try await api.fetchReleasePage(repo, owner: owner, repo: name, page: 1, etag: stored?.etag) {
            case .notModified:
                guard var listing = stored else { return nil }
                listing.checkedAt = now()
                listing.latestTag = latestTag
                listing.failedAt = nil
                await store.setListing(listing, for: repo)
                return listing
            case .page(let first, let firstETag, var hasNext):
                releases = first
                etag = firstETag
                var page = 2
                while hasNext, page <= Self.maxListingPages {
                    if keepReserve, await api.isWithinSupportReserve() { break }
                    // A later page failing (the limit reached mid-way) still leaves the newest releases.
                    guard case .page(let more, _, let next)? = try? await api.fetchReleasePage(repo, owner: owner, repo: name, page: page, etag: nil) else { break }
                    releases += more
                    hasNext = next
                    page += 1
                }
            }
            let listing = ReleaseListing(releases: ReleaseStreams.trimmed(releases), etag: etag, checkedAt: now(), latestTag: latestTag)
            await store.setListing(listing, for: repo)
            return listing
        } catch AddonError.notFound {
            let listing = ReleaseListing(releases: [], checkedAt: now(), notFound: true)
            await store.setListing(listing, for: repo)
            return listing
        } catch {
            // Kept beside the last good listing (or an empty one), retried after `errorTTL`.
            var listing = stored ?? ReleaseListing(releases: [], checkedAt: .distantPast)
            listing.failedAt = now()
            await store.setListing(listing, for: repo)
            if stored == nil { throw error }
            return listing
        }
    }

    /// A prefixed ref's latest stable release: its stream's newest in the listing, not the
    /// repo's latest (`places-audio/v2.1.0`, never `spoken/v3.8.4`). Supported when its
    /// release.json names the flavor; without one it's `.needsDownload`, like any repo
    /// without release.json. Not stored as a verdict: the listing is what's stored.
    func streamVerdict(for ref: AddonRef, flavor: Flavor, policy: CachePolicy, background: Bool) async -> LatestRelease {
        guard let prefix = ref.tagPrefix else { return LatestRelease(tag: nil, status: .unknown) }
        guard let listing = try? await listing(for: ref, flavor: flavor, policy: policy, background: background, keepReserve: true) else {
            return LatestRelease(tag: nil, status: .unknown, failed: policy != .preferStored)
        }
        let failed = listing.failedAt != nil
        guard let release = listing.releases(inStream: prefix).first(where: { !$0.prerelease }) else {
            return LatestRelease(tag: nil, status: listing.checkedAt == .distantPast ? .unknown : .noReleases, failed: failed)
        }
        let inspected = await store.storedFlavors(for: ref).flatMap { $0.tag == release.tagName ? $0.flavors : nil }
        guard release.releaseJSONAsset != nil, let (owner, name) = try? GitHubReleaseResolver.split(ref) else {
            return LatestRelease(tag: release.tagName, status: .needsDownload, failed: failed, availableFlavors: inspected, publishedAt: release.publishedAt)
        }
        let json = policy == .preferStored
            ? (await knownReleaseJSON(ref.repo, tag: release.tagName)) ?? nil
            : (try? await webReleaseJSON(owner: owner, repo: name, ref: ref.repo, tag: release.tagName, background: background)) ?? nil
        guard let json else {
            return LatestRelease(tag: release.tagName, status: .needsDownload, failed: failed, availableFlavors: inspected, publishedAt: release.publishedAt)
        }
        let build = json.release(for: flavor)
        return LatestRelease(
            tag: release.tagName, status: build != nil ? .supported(version: release.tagName) : .unsupported, build: build,
            failed: failed, availableFlavors: json.availableFlavors, publishedAt: release.publishedAt)
    }
}

// MARK: - Storage

extension SupportCache {
    func storedListing(for repo: AddonRef) async -> ReleaseListing? {
        guard let row = try? await database.query("""
            SELECT releases_json, etag, checked_at, latest_tag, not_found, failed_at FROM release_listing WHERE full_name = ?
            """, repo.key).first,
              let json = row.string(0), let checkedAt = row.date(2),
              let releases = try? GitHubRelease.decoder.decode([GitHubRelease].self, from: Data(json.utf8)) else { return nil }
        return ReleaseListing(
            releases: releases, etag: row.string(1), checkedAt: checkedAt, latestTag: row.string(3),
            notFound: row.bool(4), failedAt: row.date(5))
    }

    func setListing(_ listing: ReleaseListing, for repo: AddonRef) async {
        guard let data = try? GitHubRelease.encoder.encode(listing.releases) else { return }
        _ = try? await database.execute("""
            INSERT INTO release_listing(full_name, releases_json, etag, checked_at, latest_tag, not_found, failed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(full_name) DO UPDATE SET releases_json = excluded.releases_json, etag = excluded.etag,
                checked_at = excluded.checked_at, latest_tag = excluded.latest_tag, not_found = excluded.not_found,
                failed_at = excluded.failed_at
            """, repo.key, String(decoding: data, as: UTF8.self), listing.etag, listing.checkedAt, listing.latestTag,
            listing.notFound ? 1 : 0, listing.failedAt)
    }
}

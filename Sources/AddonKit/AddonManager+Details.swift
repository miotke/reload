import Foundation

/// The inspector's data (docs/features/details-and-screenshots.md). Opening an add-on is one of the few times
/// the core goes to the network on its own: it revalidates that repo's support verdict and
/// latest tag when stale, and its README when older than a day, all quota-free. Release
/// notes cost an API call, so they're fetched on demand (`releaseNotes`).
extension AddonManager {
    /// Stored details are reused this long.
    public static let detailsTTL: TimeInterval = 24 * 60 * 60
    /// A repo found to have no README isn't asked again for this long.
    public static let noReadmeTTL: TimeInterval = 7 * 24 * 60 * 60

    public func details(for ref: AddonRef, in installation: Installation) async throws -> AddonDetails {
        let (owner, repo) = try GitHubSource.split(ref)
        let flavor = installation.flavor
        let entry = await catalogue.entry(for: ref)
        let installed = try? await store.addons(in: installation).first { $0.id == ref }
        let stars = await supportCache.stars()[ref.identifier.lowercased()]

        var stored = await storedDetails(ref, flavor: flavor)
        let stale = stored == nil || now().timeIntervalSince(stored!.fetchedAt) >= Self.detailsTTL
        // Support and the latest tag: the single owner decides, quota-free. Fresh details
        // cost nothing, so they read what's stored.
        let latest = await github.latestRelease(for: ref, flavor: flavor, policy: stale ? .revalidateIfStale : .preferStored)
        if stale {
            stored = await fetchDetails(ref, owner: owner, repo: repo, flavor: flavor, previous: stored) ?? stored
        }
        var notes = stored.flatMap { Self.notes(in: $0, tag: latest.tag) }
        // With a token the API has quota to spare, so the notes come along automatically.
        if notes == nil, latest.tag != nil, await github.hasToken(), await github.quotaIsComfortable() {
            notes = try? await releaseNotes(for: ref, in: installation)
        }
        let storedPublishedAt = await supportCache.latestPublishedAt(for: ref)

        return AddonDetails(
            ref: ref,
            name: entry?.name ?? installed?.name ?? repo,
            owner: owner,
            summary: entry?.description,
            repositoryURL: URL(string: "https://github.com/\(owner)/\(repo)")!,
            stars: stars,
            lastUpdated: entry?.lastUpdated,
            readme: stored?.readme,
            screenshots: stored?.screenshots ?? [],
            latestVersion: latest.tag ?? stored?.latestVersion,
            latestPublishedAt: notes?.publishedAt ?? storedPublishedAt,
            latestChangelog: notes?.markdown,
            support: latest.status,
            fetchedAt: stored?.fetchedAt ?? now()
        )
    }

    /// Notes of the latest stable release: from the `details` table when stored for that
    /// tag, else one API call (`GitHubSource.releaseNotes`, no zips), then stored by tag.
    /// Nil when the repo has no releases.
    public func releaseNotes(for ref: AddonRef, in installation: Installation) async throws -> (version: String, publishedAt: Date?, markdown: String)? {
        let flavor = installation.flavor
        let tag = await github.latestRelease(for: ref, flavor: flavor, policy: .preferStored).tag
        if let stored = await storedDetails(ref, flavor: flavor), let notes = Self.notes(in: stored, tag: tag) {
            return notes
        }
        guard let notes = try await github.releaseNotes(for: ref, tag: tag) else { return nil }
        // A row created here has no README yet; its epoch `fetched_at` makes `details` fetch one.
        _ = try? await database.execute("""
            INSERT INTO details(full_name, flavor, latest_version, latest_published_at, latest_changelog, fetched_at)
            VALUES (?, ?, ?, ?, ?, 0)
            ON CONFLICT(full_name, flavor) DO UPDATE SET latest_version = excluded.latest_version,
                latest_published_at = excluded.latest_published_at, latest_changelog = excluded.latest_changelog
            """, ref.identifier, flavor.rawValue, notes.version, notes.publishedAt, notes.markdown)
        if let date = notes.publishedAt {
            await supportCache.setPublishedAt(date, ifLatestTagIs: notes.version, for: ref)
        }
        await database.notify(["details"], repos: [ref.identifier])
        return notes
    }

    /// The stored notes, if they belong to `tag` (any stored notes when the tag is unknown).
    private static func notes(in stored: StoredDetails, tag: String?) -> (version: String, publishedAt: Date?, markdown: String)? {
        guard let version = stored.latestVersion, let markdown = stored.latestChangelog, tag == nil || tag == version else { return nil }
        return (version, stored.latestPublishedAt, markdown)
    }

    struct StoredDetails: Sendable {
        var readme: String?
        var screenshots: [URL]
        /// The tag the stored release notes belong to.
        var latestVersion: String?
        var latestPublishedAt: Date?
        var latestChangelog: String?
        var fetchedAt: Date
    }

    func storedDetails(_ ref: AddonRef, flavor: Flavor) async -> StoredDetails? {
        guard let row = try? await database.query("""
            SELECT readme, screenshots_json, latest_version, latest_published_at, latest_changelog, fetched_at
            FROM details WHERE full_name = ? AND flavor = ?
            """, ref.identifier, flavor.rawValue).first, let fetched = row.date(5) else { return nil }
        let screenshots = (row.string(1).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
            .compactMap(URL.init(string:))
        return StoredDetails(readme: row.string(0), screenshots: screenshots, latestVersion: row.string(2),
                             latestPublishedAt: row.date(3), latestChangelog: row.string(4), fetchedAt: fetched)
    }

    /// Refreshes the README and its screenshots for one repo. Returns nil (and stores nothing)
    /// when the README couldn't be fetched, so a network blip isn't cached for a day. Stored
    /// release notes are kept.
    private func fetchDetails(
        _ ref: AddonRef, owner: String, repo: String, flavor: Flavor, previous: StoredDetails?
    ) async -> StoredDetails? {
        // README: remembered path and ETag first; a stored "none" is an empty path.
        let meta = try? await database.query(
            "SELECT readme_path, readme_etag, readme_checked_at FROM repo_meta WHERE full_name = ?", ref.identifier).first
        let knownPath = meta?.string(0)
        let readme: String?
        let readmePath: String?
        if knownPath == "", let checked = meta?.date(2), now().timeIntervalSince(checked) < Self.noReadmeTTL {
            // Recently found to have none: don't walk the candidate paths again.
            readme = nil
            readmePath = nil
        } else {
            do {
                switch try await github.readme(for: ref, knownPath: knownPath, etag: previous?.readme == nil ? nil : meta?.string(1)) {
                case .found(let markdown, let path, let etag):
                    readme = markdown
                    readmePath = path
                    _ = try? await database.execute("""
                        INSERT INTO repo_meta(full_name, readme_path, readme_etag, readme_checked_at) VALUES (?, ?, ?, ?)
                        ON CONFLICT(full_name) DO UPDATE SET readme_path = excluded.readme_path,
                            readme_etag = excluded.readme_etag, readme_checked_at = excluded.readme_checked_at
                        """, ref.identifier, path, etag, now())
                case .notModified:
                    readme = previous?.readme
                    readmePath = knownPath
                case .none:
                    readme = nil
                    readmePath = nil
                    _ = try? await database.execute("""
                        INSERT INTO repo_meta(full_name, readme_path, readme_etag, readme_checked_at) VALUES (?, '', NULL, ?)
                        ON CONFLICT(full_name) DO UPDATE SET readme_path = '', readme_etag = NULL, readme_checked_at = excluded.readme_checked_at
                        """, ref.identifier, now())
                }
            } catch {
                return nil
            }
        }
        let screenshots = readme.map { ReadmeImages.extract(from: $0, owner: owner, repo: repo, readmePath: readmePath ?? "README.md") } ?? []

        let details = StoredDetails(
            readme: readme, screenshots: screenshots, latestVersion: previous?.latestVersion,
            latestPublishedAt: previous?.latestPublishedAt, latestChangelog: previous?.latestChangelog, fetchedAt: now()
        )
        let screenshotsJSON = (try? JSONEncoder().encode(screenshots.map(\.absoluteString))).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        _ = try? await database.execute("""
            INSERT INTO details(full_name, flavor, readme, screenshots_json, fetched_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(full_name, flavor) DO UPDATE SET readme = excluded.readme,
                screenshots_json = excluded.screenshots_json, fetched_at = excluded.fetched_at
            """, ref.identifier, flavor.rawValue, readme, screenshotsJSON, now())
        await database.notify(["details"], repos: [ref.identifier])
        return details
    }
}

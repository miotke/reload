import Foundation

/// The inspector's data (docs/search.md#details). Opening an add-on is one of the few times
/// the core goes to the network on its own: it refreshes that repo's support verdict, latest
/// tag and README when they're older than a day, stores the result, and returns it.
extension AddonManager {
    /// Stored details are reused this long.
    public static let detailsTTL: TimeInterval = 24 * 60 * 60

    public func details(for ref: AddonRef, in installation: Installation) async throws -> AddonDetails {
        let (owner, repo) = try GitHubSource.split(ref)
        let flavor = installation.flavor
        let entry = await catalogue.entry(for: ref)
        let installed = try? await store.addons(in: installation).first { $0.id == ref }
        let stars = await supportCache.stars()[ref.identifier.lowercased()]

        var stored = await storedDetails(ref, flavor: flavor)
        if stored == nil || now().timeIntervalSince(stored!.fetchedAt) >= Self.detailsTTL {
            stored = await fetchDetails(ref, owner: owner, repo: repo, flavor: flavor, previous: stored) ?? stored
        }
        // The verdict comes from the support table, which a refresh may have updated since.
        let support = await supportCache.status(for: ref, flavor: flavor) ?? .unknown
        let latestTag = await supportCache.latestTag(for: ref)?.tag
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
            latestVersion: stored?.latestVersion ?? Self.version(of: support) ?? latestTag,
            latestPublishedAt: stored?.latestPublishedAt ?? storedPublishedAt,
            latestChangelog: stored?.latestChangelog,
            support: support,
            fetchedAt: stored?.fetchedAt ?? now()
        )
    }

    private static func version(of status: SupportStatus) -> String? {
        if case .supported(let version) = status { return version }
        return nil
    }

    struct StoredDetails: Sendable {
        var readme: String?
        var screenshots: [URL]
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

    /// Refreshes support, README and the latest release for one repo. Returns nil (and stores
    /// nothing) when the README couldn't be fetched, so a network blip isn't cached for a day.
    private func fetchDetails(
        _ ref: AddonRef, owner: String, repo: String, flavor: Flavor, previous: StoredDetails?
    ) async -> StoredDetails? {
        // Support: quota-free, and only if the stored verdict is stale.
        _ = await github.check(ref, flavor: flavor, policy: .revalidateIfStale)

        // README: remembered path and ETag first; a stored "none" is an empty path.
        let meta = try? await database.query(
            "SELECT readme_path, readme_etag FROM repo_meta WHERE full_name = ?", ref.identifier).first
        let knownPath = meta?.string(0)
        let readme: String?
        let readmePath: String?
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
        let screenshots = readme.map { ReadmeImages.extract(from: $0, owner: owner, repo: repo, readmePath: readmePath ?? "README.md") } ?? []

        // Latest release notes cost an API call; only spend it when quota is comfortable.
        var latestVersion: String?
        var latestPublishedAt: Date?
        var latestChangelog: String?
        if await github.quotaIsComfortable(),
           case .release(let release, _)? = try? await github.resolve(ref, flavor: flavor, channel: .stable, etag: nil) {
            latestVersion = release.version
            latestPublishedAt = release.publishedAt
            latestChangelog = release.changelog
            await supportCache.setPublishedAt(release.publishedAt, ifLatestTagIs: release.version, for: ref)
        } else {
            latestVersion = previous?.latestVersion
            latestPublishedAt = previous?.latestPublishedAt
            latestChangelog = previous?.latestChangelog
        }

        let details = StoredDetails(
            readme: readme, screenshots: screenshots, latestVersion: latestVersion,
            latestPublishedAt: latestPublishedAt, latestChangelog: latestChangelog, fetchedAt: now()
        )
        let screenshotsJSON = (try? JSONEncoder().encode(screenshots.map(\.absoluteString))).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        _ = try? await database.execute("""
            INSERT INTO details(full_name, flavor, readme, screenshots_json, latest_version, latest_published_at, latest_changelog, fetched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(full_name, flavor) DO UPDATE SET readme = excluded.readme, screenshots_json = excluded.screenshots_json,
                latest_version = excluded.latest_version, latest_published_at = excluded.latest_published_at,
                latest_changelog = excluded.latest_changelog, fetched_at = excluded.fetched_at
            """, ref.identifier, flavor.rawValue, readme, screenshotsJSON, latestVersion, latestPublishedAt, latestChangelog, now())
        await database.notify(["details"], repos: [ref.identifier])
        return details
    }
}

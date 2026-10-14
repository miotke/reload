import Foundation

/// Add-on sources (docs/features/sources.md): which ones search and Browse use, and
/// resolving, update checks and details for add-ons from WoWInterface and Tukui.
extension AddonManager {
    // MARK: - Settings

    /// Every source, in display order, with whether search and Browse use it.
    public func sources() async -> [SourceSetting] {
        let enabled = await database.enabledSources()
        return SourceID.allCases.map { SourceSetting(source: $0, isEnabled: enabled.contains($0)) }
    }

    /// Turns a source's search and Browse results on or off. Installed add-ons from it are
    /// unaffected: they stay listed and keep getting update checks.
    public func setSource(_ source: SourceID, enabled: Bool) async throws {
        try await database.setSource(source, enabled: enabled)
    }

    // MARK: - Listings

    /// Downloads the listings of the hosted sources that are on, when older than 24 h (or
    /// always with `force`). Failures are skipped: the stored rows keep working.
    func refreshHostedListings(force: Bool) async {
        let enabled = await database.enabledSources()
        for source in HostedSources.all where enabled.contains(source.id) {
            _ = try? await hosted.refresh(source.id, force: force)
        }
    }

    // MARK: - Resolving

    /// The host's latest file for `ref`, if its zip has a build for `flavor`. Hosts don't say
    /// which games a file supports, so this downloads the zip (into the cache the install
    /// then reuses) and reads its TOCs, and records the flavors it ships.
    /// - Throws: `AddonError.noCompatibleRelease` when the zip has no TOC `flavor` loads.
    func resolveHosted(_ ref: AddonRef, flavor: Flavor, policy: CachePolicy) async throws -> ResolvedRelease {
        let file = try await hosted.file(for: ref, policy: policy)
        var release = file.release(for: ref)
        let archive = try await downloader.download(release)
        let (support, available) = try await Self.inspectHosted(archive, flavor: flavor)
        if !available.isEmpty {
            await supportCache.setAvailableFlavors(available, tag: release.version, source: .inspection, for: ref)
        }
        release.reasoning.append(support.detail)
        guard support.isSupported else { throw AddonError.noCompatibleRelease(ref, flavor) }
        return release
    }

    @concurrent
    private static func inspectHosted(_ archive: URL, flavor: Flavor) async throws -> (FlavorSupport, Set<Flavor>) {
        (try ZipInspector.inspect(zipAt: archive, flavor: flavor), try ZipInspector.availableFlavors(zipAt: archive))
    }

    /// An installed hosted add-on's update state. The host's latest version (an hour-old
    /// answer is reused unless `policy` forces a request) decides whether there's anything
    /// new; only a new version's zip is downloaded, to check it still has the build in use.
    func hostedUpdateState(of addon: InstalledAddon, in installation: Installation, policy: CachePolicy) async -> UpdateState {
        let own = installation.flavor
        let build = addon.installedFlavorBuild ?? own
        do {
            let file = try await hosted.file(for: addon.id, policy: policy)
            var latest = file.release(for: addon.id)
            latest.flavorBuild = addon.installedFlavorBuild
            guard addon.isUpdate(latest) else { return .upToDate }
            // On a fallback build, a new version with the installation's own build is the update.
            if build != own, let release = try? await resolveHosted(addon.id, flavor: own, policy: .preferStored) {
                return .available(release)
            }
            var release = try await resolveHosted(addon.id, flavor: build, policy: .preferStored)
            release.flavorBuild = build == own ? nil : build
            return .available(release)
        } catch AddonError.noCompatibleRelease {
            return .noCompatibleRelease
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Details

    /// The inspector's details from the host's listing and latest file. Asks the host only
    /// when the stored file is older than a day (`detailsTTL`), like a GitHub README.
    func hostedDetails(for ref: AddonRef, in installation: Installation) async throws -> AddonDetails {
        let entry = await catalogue.entry(for: ref)
        let stored = await database.hostedFile(ref)
        let file: HostedFile
        if let stored, now().timeIntervalSince(stored.fetchedAt) < Self.detailsTTL {
            file = stored.file
        } else if let fetched = try? await hosted.file(for: ref, policy: .forceRevalidate) {
            file = fetched
        } else if let stored {
            file = stored.file
        } else {
            throw AddonError.notFound(ref)
        }
        let installed = try? await store.addons(in: installation).first { $0.id == ref }
        let flavors = await supportCache.availableFlavors(for: ref) ?? entry?.listedFlavors
        let support: SupportStatus = flavors?.contains(installation.flavor) == true ? .supported(version: file.version) : .needsDownload
        let screenshots = file.screenshots.isEmpty ? entry?.screenshots ?? [] : file.screenshots
        return AddonDetails(
            ref: ref,
            name: entry?.name ?? installed?.name ?? file.name,
            owner: file.author ?? entry?.author ?? "",
            summary: entry?.description,
            repositoryURL: ref.webURL ?? entry?.url ?? file.downloadURL,
            lastUpdated: file.publishedAt,
            readme: file.summary,
            screenshots: screenshots,
            latestVersion: file.version,
            latestPublishedAt: file.publishedAt,
            latestChangelog: file.changelog,
            support: support,
            availableFlavors: flavors,
            fetchedAt: now()
        )
    }

    /// The latest file's changelog, from the stored file or one request to the host.
    func hostedReleaseNotes(for ref: AddonRef) async throws -> (version: String, publishedAt: Date?, markdown: String)? {
        let file = try await hosted.file(for: ref, policy: .preferStored)
        guard let changelog = file.changelog, !changelog.isEmpty else { return nil }
        return (file.version, file.publishedAt, changelog)
    }
}

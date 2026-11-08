import Foundation

/// Optional parts and tag streams: repos that publish several add-ons from one repo
/// (docs/features/optional-parts.md).
extension AddonManager {
    public func optionalParts(of ref: AddonRef, in installation: Installation, policy: CachePolicy) async throws -> [OptionalPart] {
        guard ref.source == .github, let managed = try? await store.addons(in: installation),
              let addon = managed.first(where: { $0.id == ref }) else { return [] }
        let scan = await Self.scanOptionalDependencies(addon, in: installation)
        guard !scan.wanted.isEmpty,
              let listing = try await github.latest.listing(for: ref, flavor: installation.flavor, policy: policy, keepReserve: true)
        else { return [] }
        // The add-on's own stream is never one of its parts.
        let own = ReleaseStreams.followedPrefix(ref: ref, installedTag: addon.version).map { Set([$0]) } ?? []
        var parts: [OptionalPart] = []
        for (folder, usedBy) in scan.wanted {
            guard let match = ReleaseStreams.match(folder: folder, in: listing.releases, excluding: own) else { continue }
            let part = AddonRef(source: .github, identifier: ref.identifier, tagPrefix: match.prefix)
            let state: OptionalPart.State
            if let owner = managed.first(where: { $0.folders.contains { Installer.same($0, folder) } }) {
                // Another add-on ships that folder: it isn't this part to offer.
                guard owner.id.isSameAddon(as: part) else { continue }
                state = .installed
            } else {
                state = scan.present.contains(folder.lowercased()) ? .unmanaged : .available
            }
            parts.append(OptionalPart(
                ref: owner(of: part, in: managed) ?? part, folder: folder, usedBy: usedBy, version: match.release.tagName,
                downloadSize: Int64(match.asset.size), state: state))
        }
        return parts.sorted { $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
    }

    /// The managed ref for `part` as stored (its prefix's case), when it's installed.
    private func owner(of part: AddonRef, in managed: [InstalledAddon]) -> AddonRef? {
        managed.first { $0.id.isSameAddon(as: part) }?.id
    }

    struct OptionalScan: Sendable {
        /// Lower-cased names of every folder in `AddOns/`.
        var present: Set<String> = []
        /// Folders the loaded TOCs list in `OptionalDeps`, as spelled, with the add-on's
        /// folders that list each; never its own folders or `Blizzard_*`.
        var wanted: [(folder: String, usedBy: [String])] = []
    }

    /// Reads the TOC the game loads in each of the add-on's folders (the rule
    /// `scanDependencies` uses), off the actor.
    @concurrent
    static func scanOptionalDependencies(_ addon: InstalledAddon, in installation: Installation) async -> OptionalScan {
        let directory = installation.addonsDirectory
        var scan = OptionalScan()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for entry in entries where !entry.hasPrefix(".") && InstallStore.isDirectory(directory.appending(path: entry, directoryHint: .isDirectory)) {
            scan.present.insert(entry.lowercased())
        }
        let own = Set(addon.folders.map { $0.lowercased() })
        var index: [String: Int] = [:]
        for folder in addon.folders where scan.present.contains(folder.lowercased()) {
            let tocs = ZipInspector.readTocs(addonFolder: directory.appending(path: folder, directoryHint: .isDirectory), flavor: installation.flavor)
            guard tocs.isLoaded, let loaded = tocs.loaded else { continue }
            for dependency in loaded.toc.optionalDependencies {
                let key = dependency.lowercased()
                guard !Installer.isProtected(dependency), !own.contains(key) else { continue }
                if let i = index[key] {
                    if !scan.wanted[i].usedBy.contains(folder) { scan.wanted[i].usedBy.append(folder) }
                } else {
                    index[key] = scan.wanted.count
                    scan.wanted.append((dependency, [folder]))
                }
            }
        }
        return scan
    }

    // MARK: - Resolving a stream

    /// Resolves `ref` within the tag stream `prefix` over the stored listing
    /// (docs/features/optional-parts.md#resolving-a-stream): no API call unless the listing
    /// is out of date, and no zip downloaded to inspect unless the stream leaves a choice.
    /// Background checks keep the quota reserve and never inspect zips.
    func resolveStream(
        _ ref: AddonRef, prefix: String, flavor: Flavor, channel: Channel, policy: CachePolicy,
        installed: InstalledAddon?, background: Bool = false
    ) async throws -> ResolvedRelease {
        guard let listing = try await github.latest.listing(
            for: ref, flavor: flavor, policy: policy, background: background, keepReserve: background) else {
            throw AddonError.noCompatibleRelease(ref, flavor)
        }
        if listing.notFound { throw AddonError.notFound(ref.repo) }
        if listing.releases.isEmpty, listing.failedAt != nil { throw URLError(.cannotLoadFromNetwork) }
        return try await github.source.resolve(
            ref, within: listing.releases, prefix: prefix, flavor: flavor, channel: channel,
            installed: installed.map { ($0.assetName, $0.version) }, downloadZips: !background)
    }

    /// The update state of an add-on that follows a tag stream. An unchanged repo-wide latest
    /// tag equal to the installed one settles it for free; otherwise the stream's newest
    /// release in the listing decides. Stays on the installed build: a stream's zips aren't
    /// inspected, so a switch to another game's build can't be told apart.
    func streamUpdateState(
        of addon: InstalledAddon, prefix: String, build: Flavor, own: Flavor, policy: CachePolicy, background: Bool
    ) async throws -> (UpdateState, String?) {
        var listingPolicy = policy
        if addon.channel == .stable {
            let latest = await github.latest.latestRelease(for: addon.id.repo, flavor: build, policy: policy, background: background)
            if !latest.failed, latest.status != .unknown {
                if latest.tag == addon.version { return (.upToDate, addon.etag) }
                // The tag was just asked for; the listing reuses it instead of asking again.
                if policy == .forceRevalidate { listingPolicy = .revalidateIfStale }
            }
        }
        var release = try await resolveStream(
            addon.id, prefix: prefix, flavor: build, channel: addon.channel, policy: listingPolicy, installed: addon, background: background)
        release.flavorBuild = build == own ? nil : build
        return addon.isUpdate(release) ? (.available(release), nil) : (.upToDate, addon.etag)
    }

    /// A prefixed ref's release notes: its stream's newest stable release in the stored listing.
    func streamNotes(_ ref: AddonRef, flavor: Flavor) async -> (version: String, publishedAt: Date?, markdown: String)? {
        guard let prefix = ref.tagPrefix,
              let listing = try? await github.latest.listing(for: ref, flavor: flavor, policy: .preferStored),
              let release = listing.releases(inStream: prefix).first(where: { !$0.prerelease }) else { return nil }
        return (release.tagName, release.publishedAt ?? release.createdAt, release.body ?? "")
    }
}

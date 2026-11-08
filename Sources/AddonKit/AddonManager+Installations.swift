import Foundation

/// Installations and the add-ons in them (docs/features/finding-wow.md).
extension AddonManager {
    /// Stored installations. The first call in a process runs detection if nothing is stored
    /// yet, or if a stored installation's folder is gone (it may have been renamed).
    public func installations() async throws -> [Installation] {
        let stored = try await store.installations()
        guard !didAutoDetect, stored.isEmpty || stored.contains(where: Self.isMissing) else { return stored }
        didAutoDetect = true
        return try await detectInstallations()
    }

    /// Scans for WoW installs and stores any that aren't known yet. A new install that
    /// replaces a stored one whose folder is gone (Forever moved from `_classic_beta_` to
    /// `_forever_` at launch) takes over its records. Returns all stored installations.
    @discardableResult
    public func detectInstallations() async throws -> [Installation] {
        let stored = try await store.installations()
        let known = Set(stored.map(\.id))
        let found = await locator.locate().filter { !known.contains($0.id) }
        for installation in found {
            if let old = Self.predecessor(of: installation, stored: stored, found: found) {
                try await store.move(installationID: old.id, to: installation)
            } else {
                try await store.save(installation)
            }
        }
        return try await store.installations()
    }

    /// The stored installation `installation` replaces: missing from disk, same flavor, same
    /// `World of Warcraft` folder, and the only match each way, so a guess never merges two installs.
    static func predecessor(of installation: Installation, stored: [Installation], found: [Installation]) -> Installation? {
        func sameGame(_ a: Installation, _ b: Installation) -> Bool {
            a.flavor == b.flavor && a.root.deletingLastPathComponent().standardizedFileURL == b.root.deletingLastPathComponent().standardizedFileURL
        }
        let candidates = stored.filter { isMissing($0) && sameGame($0, installation) }
        guard candidates.count == 1, let old = candidates.first,
              found.filter({ sameGame($0, old) }).count == 1 else { return nil }
        return old
    }

    static func isMissing(_ installation: Installation) -> Bool {
        !FileManager.default.fileExists(atPath: installation.root.path(percentEncoded: false))
    }

    public func addInstallation(at url: URL) async throws -> Installation {
        let installation = try locator.installation(at: url)
        try await store.save(installation)
        return installation
    }

    public func removeInstallation(_ installation: Installation) async throws {
        try await store.remove(installationID: installation.id)
    }

    // MARK: - Add-ons

    /// Reconciles the store with disk, then suggests repos for unmanaged folders from the
    /// local catalogue and groups the folders one release covers. No network.
    public func addons(in installation: Installation) async throws -> [AddonStatus] {
        let statuses = try await store.reconcile(installation)
        let unmanaged = statuses.compactMap(\.unmanagedFolder)
        guard !unmanaged.isEmpty else { return statuses }
        let index = await catalogue.adoptionIndex()
        let grouped = AdoptionIndex.group(unmanaged.map(index.suggesting), releaseFolders: await database.releaseFolders())
        return statuses.filter { $0.unmanagedFolder == nil } + grouped.map(AddonStatus.unmanaged)
    }

    /// Managed add-ons only, straight from the store.
    public func installedAddons(in installation: Installation) async throws -> [InstalledAddon] {
        try await store.addons(in: installation)
    }

    /// Turns user input into refs: an `owner/repo` or URL, an installed add-on's name or
    /// folder, or an exact catalogue name. More than one result means the input is ambiguous.
    public func lookup(_ input: String, in installation: Installation) async throws -> [AddonRef] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ref = AddonRef(parsing: text) { return [ref] }

        let installed = try await store.addons(in: installation)
        let installedMatches = installed.filter { addon in
            addon.name.caseInsensitiveCompare(text) == .orderedSame
                || addon.id.identifier.split(separator: "/").last.map { $0.caseInsensitiveCompare(text) == .orderedSame } == true
                || addon.folders.contains { $0.caseInsensitiveCompare(text) == .orderedSame }
        }
        if !installedMatches.isEmpty { return installedMatches.map(\.id) }

        let entries = try await catalogue.entries()
        let exact = entries.filter { entry in
            entry.name.caseInsensitiveCompare(text) == .orderedSame
                || entry.fullName.split(separator: "/").last.map { $0.caseInsensitiveCompare(text) == .orderedSame } == true
        }
        return exact.map(\.ref)
    }
}

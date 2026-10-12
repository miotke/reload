import Foundation

/// Installs and uninstalls add-on archives in an installation's `Interface/AddOns`
/// folder, transactionally (docs/features/installing.md).
///
/// The installer only moves folders around; it doesn't persist anything. The caller
/// writes the returned `InstalledAddon` to the `InstallStore`.
public struct Installer: Sendable {
    /// Disposes of a folder during uninstall. The default moves it to the Trash.
    public typealias TrashHandler = @Sendable (URL) throws -> Void

    /// A point in the folder swap where tests can inject a failure.
    enum SwapStep: Equatable, Sendable {
        /// About to move the existing `folder` out of `AddOns/` into the backup area.
        case backup(String)
        /// About to move the new `folder` from staging into `AddOns/`.
        case moveIn(String)
    }

    let trash: TrashHandler
    /// Test hook: called before every move in the swap; throwing aborts the swap.
    var faultInjection: (@Sendable (SwapStep) throws -> Void)?
    /// Test hook: forces the hidden-sibling staging fallback.
    var forceSiblingStaging = false

    public init(trash: @escaping TrashHandler = Installer.moveToTrash) {
        self.trash = trash
    }

    /// Moves `url` to the user's Trash.
    public static let moveToTrash: TrashHandler = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Prefix of folders the installer never creates, replaces or removes.
    public static let protectedPrefix = "Blizzard_"

    // MARK: - Install

    /// An archive validated and extracted into staging on the AddOns volume, ready for
    /// `commit`. Extraction is the slow part (about 106 ms for 8 MB), so callers do it
    /// before taking the store lock.
    public struct PreparedInstall: Sendable {
        let addonsDirectory: URL
        let staging: URL
        /// The archive's top-level folders, sorted.
        public let folders: [String]

        var extracted: URL { staging.appending(path: "new", directoryHint: .isDirectory) }
        var backup: URL { staging.appending(path: "backup", directoryHint: .isDirectory) }

        /// Deletes the staging folder when `commit` never ran. A folder still holding
        /// backups a failed swap couldn't put back is kept rather than lose data.
        public func discard() {
            let fm = FileManager.default
            let backups = (try? fm.contentsOfDirectory(atPath: backup.path(percentEncoded: false))) ?? []
            guard backups.isEmpty else { return }
            try? fm.removeItem(at: staging)
        }
    }

    /// Installs `archive` (the asset of `release`) into `installation`: `prepare`, then `commit`.
    ///
    /// - Parameters:
    ///   - current: Every managed add-on in `installation`, used for ownership checks.
    ///   - force: Overwrite folders that exist on disk but no managed add-on owns.
    /// - Returns: The new record. `channel`, `pinned` and `etag` carry over from the
    ///   previous install of `release.ref`, if any.
    /// - Throws: `AddonError.folderConflict`, `.unmanagedFolderExists`, archive errors,
    ///   or the file-system error that aborted the swap (after restoring the backups).
    public func install(
        archive: URL,
        into installation: Installation,
        release: ResolvedRelease,
        current: [InstalledAddon],
        force: Bool,
        now: Date = Date()
    ) throws -> InstalledAddon {
        let prepared = try prepare(archive: archive, into: installation)
        return try commit(prepared, release: release, current: current, force: force, now: now)
    }

    /// Steps 1 and 3 of an install: validates `archive` and extracts it into a staging folder
    /// on the same volume as `AddOns/`. Touches nothing in `AddOns/` and needs no store state.
    public func prepare(archive: URL, into installation: Installation) throws -> PreparedInstall {
        let fm = FileManager.default
        let addonsDirectory = installation.addonsDirectory

        // 1. Validate the zip before touching anything.
        let newFolders = try ZipExtractor.topLevelFolders(in: archive)
        for folder in newFolders where Self.isProtected(folder) {
            throw AddonError.invalidArchive("archive contains protected folder \(folder)")
        }

        // 3. Extract to staging on the same volume, so the swap is a rename.
        try fm.createDirectory(at: addonsDirectory, withIntermediateDirectories: true)
        let staging = try makeStagingDirectory(for: addonsDirectory)
        do {
            let prepared = PreparedInstall(addonsDirectory: addonsDirectory, staging: staging, folders: [])
            try fm.createDirectory(at: prepared.backup, withIntermediateDirectories: true)
            let folders = try ZipExtractor.extract(archive, to: prepared.extracted)
            return PreparedInstall(addonsDirectory: addonsDirectory, staging: staging, folders: folders)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Steps 2, 4 and 5: the ownership check against `current`, the swap, and the new
    /// record. Run it under the store lock. The staging folder is removed whatever happens,
    /// except when a failed swap leaves backups it couldn't restore.
    public func commit(
        _ prepared: PreparedInstall,
        release: ResolvedRelease,
        current: [InstalledAddon],
        force: Bool,
        now: Date = Date()
    ) throws -> InstalledAddon {
        let fm = FileManager.default
        let ref = release.ref
        let addonsDirectory = prepared.addonsDirectory
        let previous = current.first { $0.id == ref }
        let newFolders = prepared.folders
        var keepStaging = false
        defer {
            if !keepStaging { try? fm.removeItem(at: prepared.staging) }
        }

        // 2. Ownership.
        for folder in newFolders {
            if let owner = current.first(where: { $0.id != ref && $0.folders.contains(where: { Self.same($0, folder) }) }) {
                throw AddonError.folderConflict(folder: folder, owner: owner.id)
            }
            let ownedBySelf = previous?.folders.contains { Self.same($0, folder) } ?? false
            if !ownedBySelf, !force, fm.fileExists(atPath: addonsDirectory.appending(path: folder).path(percentEncoded: false)) {
                throw AddonError.unmanagedFolderExists(folder)
            }
        }
        let dropped = (previous?.folders ?? []).filter { old in
            Self.isSafeFolderName(old) && !Self.isProtected(old)
                && !newFolders.contains { Self.same($0, old) }
                && !current.contains { $0.id != ref && $0.folders.contains { Self.same($0, old) } }
        }

        let folders = newFolders
        let extracted = prepared.extracted
        let backup = prepared.backup

        // 4. Swap.
        var journal: [SwapStep] = []
        do {
            for folder in folders {
                let destination = addonsDirectory.appending(path: folder, directoryHint: .isDirectory)
                if Self.exists(destination) {
                    try faultInjection?(.backup(folder))
                    try fm.moveItem(at: destination, to: backup.appending(path: folder))
                    journal.append(.backup(folder))
                }
                try faultInjection?(.moveIn(folder))
                try fm.moveItem(at: extracted.appending(path: folder), to: destination)
                journal.append(.moveIn(folder))
            }
            for folder in dropped {
                let destination = addonsDirectory.appending(path: folder, directoryHint: .isDirectory)
                guard Self.exists(destination) else { continue }
                try faultInjection?(.backup(folder))
                try fm.moveItem(at: destination, to: backup.appending(path: folder))
                journal.append(.backup(folder))
            }
        } catch {
            if !rollBack(journal, addonsDirectory: addonsDirectory, backup: backup, staging: extracted) {
                // Some backup couldn't be put back; keep it on disk rather than lose data.
                keepStaging = true
            }
            throw error
        }

        // 5. Commit.
        return InstalledAddon(
            id: ref,
            name: release.name,
            folders: folders,
            version: release.version,
            releaseID: release.releaseID,
            assetName: release.assetName,
            publishedAt: release.publishedAt,
            installedAt: now,
            channel: previous?.channel ?? .stable,
            pinned: previous?.pinned ?? false,
            etag: previous?.etag
        )
    }

    /// Undoes `journal` in reverse order. Returns false if anything couldn't be restored.
    private func rollBack(_ journal: [SwapStep], addonsDirectory: URL, backup: URL, staging: URL) -> Bool {
        let fm = FileManager.default
        var ok = true
        for step in journal.reversed() {
            do {
                switch step {
                case .moveIn(let folder):
                    try fm.moveItem(at: addonsDirectory.appending(path: folder), to: staging.appending(path: folder))
                case .backup(let folder):
                    try fm.moveItem(at: backup.appending(path: folder), to: addonsDirectory.appending(path: folder))
                }
            } catch {
                ok = false
            }
        }
        return ok
    }

    private func makeStagingDirectory(for addonsDirectory: URL) throws -> URL {
        let fm = FileManager.default
        if !forceSiblingStaging,
           let url = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: addonsDirectory, create: true) {
            return url
        }
        let sibling = addonsDirectory.deletingLastPathComponent()
            .appending(path: ".\(AppInfo.name)-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        return sibling
    }

    // MARK: - Uninstall

    /// Moves `addon`'s folders out of `installation` with the trash handler.
    /// Folders already gone are skipped; `Blizzard_*` and malformed names are never touched.
    public func uninstall(_ addon: InstalledAddon, from installation: Installation) throws {
        for folder in addon.folders where Self.isSafeFolderName(folder) && !Self.isProtected(folder) {
            let url = installation.addonsDirectory.appending(path: folder, directoryHint: .isDirectory)
            guard Self.exists(url) else { continue }
            try trash(url)
        }
    }

    /// Moves folders nobody manages out of `installation` with the trash handler. Checks every
    /// name before moving anything, so a refusal leaves `AddOns/` untouched. Duplicates
    /// (compared case-insensitively) are removed once. Returns the names as found on disk.
    /// - Throws: `AddonError.cannotRemove` for `Blizzard_*`, a folder in `managed`, a name
    ///   that isn't one folder directly in `AddOns/`, or a folder that isn't there.
    public func removeUnmanaged(_ folders: [String], from installation: Installation, managed: [InstalledAddon]) throws -> [String] {
        let fm = FileManager.default
        let addonsDirectory = installation.addonsDirectory
        let onDisk = (try? fm.contentsOfDirectory(atPath: addonsDirectory.path(percentEncoded: false))) ?? []
        var targets: [String] = []
        for folder in folders {
            guard Self.isSafeFolderName(folder), folder != "..", folder != "." else {
                throw AddonError.cannotRemove(folder: folder, reason: "isn't a folder in Interface/AddOns")
            }
            guard !Self.isProtected(folder) else {
                throw AddonError.cannotRemove(folder: folder, reason: "belongs to the game")
            }
            if let owner = managed.first(where: { $0.folders.contains { Self.same($0, folder) } }) {
                throw AddonError.cannotRemove(folder: folder, reason: "is managed as \(owner.id.identifier); uninstall that instead")
            }
            var isDirectory: ObjCBool = false
            guard let name = onDisk.first(where: { Self.same($0, folder) }),
                  fm.fileExists(atPath: addonsDirectory.appending(path: name).path(percentEncoded: false), isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AddonError.cannotRemove(folder: folder, reason: "isn't in Interface/AddOns")
            }
            if !targets.contains(where: { Self.same($0, name) }) { targets.append(name) }
        }
        for name in targets {
            try trash(addonsDirectory.appending(path: name, directoryHint: .isDirectory))
        }
        return targets
    }

    // MARK: - Helpers

    static func isProtected(_ folder: String) -> Bool {
        folder.lowercased().hasPrefix(protectedPrefix.lowercased())
    }

    /// A single, non-hidden path component (guards against a corrupted store).
    static func isSafeFolderName(_ folder: String) -> Bool {
        !folder.isEmpty && !folder.hasPrefix(".") && !folder.contains("/") && !folder.contains("\\") && !folder.contains("\0")
    }

    /// Folder names compare case-insensitively, like the default APFS volume.
    static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// True if anything (including a dangling symlink) exists at `url`.
    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
    }
}

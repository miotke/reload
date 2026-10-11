import Foundation

/// Installs and uninstalls add-on archives in an installation's `Interface/AddOns`
/// folder, transactionally (docs/design.md §6.8).
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

    /// Installs `archive` (the asset of `release`) into `installation`.
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
        let fm = FileManager.default
        let ref = release.ref
        let addonsDirectory = installation.addonsDirectory
        let previous = current.first { $0.id == ref }

        // 1. Validate the zip before touching anything.
        let newFolders = try ZipExtractor.topLevelFolders(in: archive)
        for folder in newFolders where Self.isProtected(folder) {
            throw AddonError.invalidArchive("archive contains protected folder \(folder)")
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

        // 3. Extract to staging on the same volume.
        try fm.createDirectory(at: addonsDirectory, withIntermediateDirectories: true)
        let staging = try makeStagingDirectory(for: addonsDirectory)
        var keepStaging = false
        defer {
            if !keepStaging { try? fm.removeItem(at: staging) }
        }
        let extracted = staging.appending(path: "new", directoryHint: .isDirectory)
        let backup = staging.appending(path: "backup", directoryHint: .isDirectory)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        let folders = try ZipExtractor.extract(archive, to: extracted)

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

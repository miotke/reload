import Foundation

public enum InstallStoreError: Error, Sendable, Equatable, LocalizedError {
    /// The file was written by a newer version of the app.
    case unsupportedSchemaVersion(Int, file: String)
    /// The cross-process lock file couldn't be opened or locked.
    case lockFailed(errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version, let file):
            "\(file) uses store format \(version), which this version of \(AppInfo.name) can't read."
        case .lockFailed(let code):
            "Couldn't lock the add-on database (\(String(cString: strerror(code))))."
        }
    }
}

/// Persists installations and their managed add-ons (docs/design.md §6.9).
///
/// One JSON file per installation at `<appSupport>/installations/<id>.json`. The app and
/// `addonctl` may run at once, so every write holds an exclusive `flock` on
/// `installations/.lock` and re-reads the file from disk inside the lock. Nothing is
/// cached in memory. Writes are atomic renames, so reads don't need the lock.
public actor InstallStore {
    public static let schemaVersion = 1

    /// The folder holding the store's files. Watch it to notice changes from other processes.
    public nonisolated let storeDirectory: URL

    /// `lockDepth` makes `withLock` reentrant within this actor.
    private var lockDepth = 0

    public init(directories: AppDirectories) {
        self.storeDirectory = directories.installationsDirectory
    }

    /// Uses `applicationSupportDirectory/installations`.
    public init(applicationSupportDirectory: URL) {
        self.init(directories: AppDirectories(applicationSupport: applicationSupportDirectory, caches: applicationSupportDirectory))
    }

    struct StoreFile: Codable {
        var schemaVersion: Int
        var installation: Installation
        var addons: [InstalledAddon]
    }

    // MARK: - Locking

    /// Runs `body` while holding the exclusive cross-process lock. Use it to make a
    /// read-modify-write atomic; reads inside `body` see the latest data on disk.
    /// Reentrant: store methods called from `body` reuse the held lock.
    public func withLock<T: Sendable>(_ body: @Sendable (isolated InstallStore) throws -> T) throws -> T {
        let fd = try acquireLock()
        defer { releaseLock(fd) }
        return try body(self)
    }

    /// Locked read-modify-write of one installation's add-on list. Creates the
    /// installation's file if it doesn't exist yet. Leaves the file untouched when `body`
    /// changes nothing, because the app reloads on every write to `storeDirectory`.
    @discardableResult
    public func modify<T: Sendable>(_ installation: Installation, _ body: @Sendable (inout [InstalledAddon]) throws -> T) throws -> T {
        let fd = try acquireLock()
        defer { releaseLock(fd) }
        let existing = try read(installation.id)
        var file = existing ?? StoreFile(schemaVersion: Self.schemaVersion, installation: installation, addons: [])
        let result = try body(&file.addons)
        if existing == nil || existing?.addons != file.addons {
            try write(file)
        }
        return result
    }

    /// Takes the `flock`, or just bumps the depth if this actor already holds it.
    /// Returns the descriptor to release, or nil for a nested acquisition.
    private func acquireLock() throws -> Int32? {
        if lockDepth > 0 {
            lockDepth += 1
            return nil
        }
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let path = storeDirectory.appending(path: ".lock").path(percentEncoded: false)
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw InstallStoreError.lockFailed(errno: errno) }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let code = errno
            close(fd)
            throw InstallStoreError.lockFailed(errno: code)
        }
        lockDepth = 1
        return fd
    }

    private func releaseLock(_ fd: Int32?) {
        lockDepth -= 1
        if let fd {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }

    // MARK: - Installations

    /// Every stored installation, sorted by root path. Unreadable files are skipped.
    public func installations() throws -> [Installation] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeDirectory.path(percentEncoded: false)) else { return [] }
        let names = try fm.contentsOfDirectory(atPath: storeDirectory.path(percentEncoded: false))
        return names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .compactMap { name in try? readInstallation(String(name.dropLast(5))) }
            .sorted { $0.root.path < $1.root.path }
    }

    /// Adds or updates `installation`, keeping its add-ons.
    public func save(_ installation: Installation) throws {
        try withLock { store in
            let existing = try store.read(installation.id)
            guard existing?.installation != installation else { return }
            var file = existing ?? StoreFile(schemaVersion: Self.schemaVersion, installation: installation, addons: [])
            file.installation = installation
            try store.write(file)
        }
    }

    /// Forgets an installation and all its records. Doesn't touch the game folder.
    public func remove(installationID: String) throws {
        try withLock { store in
            let url = store.fileURL(installationID)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Add-ons

    /// Managed add-ons in `installation`, sorted by name. Empty if nothing is stored.
    public func addons(in installation: Installation) throws -> [InstalledAddon] {
        try read(installation.id)?.addons ?? []
    }

    /// Inserts or replaces the record for `addon.id`. Saves `installation` if new.
    public func upsert(_ addon: InstalledAddon, in installation: Installation) throws {
        try modify(installation) { addons in
            if let index = addons.firstIndex(where: { $0.id == addon.id }) {
                addons[index] = addon
            } else {
                addons.append(addon)
            }
        }
    }

    /// Removes the record for `ref`. No error if it isn't there.
    public func remove(ref: AddonRef, in installation: Installation) throws {
        try modify(installation) { addons in
            addons.removeAll { $0.id == ref }
        }
    }

    // MARK: - Reconcile

    /// Compares the store with `AddOns/` on disk (docs/design.md §6.9). Managed add-ons come
    /// first (sorted by name), then unmanaged folders (sorted by folder name).
    /// `Blizzard_*` and hidden entries are never listed.
    public func reconcile(_ installation: Installation) throws -> [AddonStatus] {
        let fm = FileManager.default
        let addonsDirectory = installation.addonsDirectory
        let managed = try addons(in: installation)

        var statuses: [AddonStatus] = managed
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { addon in
                let missing = addon.folders.filter { !Self.isDirectory(addonsDirectory.appending(path: $0, directoryHint: .isDirectory)) }
                return .managed(addon, missingFolders: missing)
            }

        let owned = Set(managed.flatMap(\.folders).map { $0.lowercased() })
        let entries = (try? fm.contentsOfDirectory(atPath: addonsDirectory.path(percentEncoded: false))) ?? []
        let unmanaged = entries
            .filter { !$0.hasPrefix(".") && !Installer.isProtected($0) && !owned.contains($0.lowercased()) }
            .filter { Self.isDirectory(addonsDirectory.appending(path: $0, directoryHint: .isDirectory)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for folder in unmanaged {
            let toc = Self.readToc(folder: folder, in: addonsDirectory)
            statuses.append(.unmanaged(folder: folder, toc: toc, suggestedRef: toc?.website.flatMap(Self.githubRef(fromWebsite:))))
        }
        return statuses
    }

    /// Parses `F/F.toc`, or else the first `F/F*.toc` (preferring base-name matches).
    static func readToc(folder: String, in addonsDirectory: URL) -> Toc? {
        let dir = addonsDirectory.appending(path: folder, directoryHint: .isDirectory)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) else { return nil }
        let lowerFolder = folder.lowercased()
        let candidates = files.filter {
            let lower = $0.lowercased()
            return lower.hasPrefix(lowerFolder) && lower.hasSuffix(".toc")
        }
        let chosen = candidates.first { $0.lowercased() == lowerFolder + ".toc" }
            ?? candidates.sorted().first { TocFileName($0)?.addonName.lowercased() == lowerFolder }
            ?? candidates.sorted().first
        guard let chosen, let data = try? Data(contentsOf: dir.appending(path: chosen)) else { return nil }
        return Toc(parsing: data)
    }

    /// `https://github.com/owner/repo[/…]` → `github:owner/repo`.
    static func githubRef(fromWebsite website: String) -> AddonRef? {
        var text = website.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text),
              let host = components.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var repo = parts[1]
        if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !parts[0].isEmpty, !repo.isEmpty,
              parts[0].unicodeScalars.allSatisfy(allowed.contains),
              repo.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return AddonRef(source: .github, identifier: "\(parts[0])/\(repo)")
    }

    // MARK: - File I/O

    func fileURL(_ installationID: String) -> URL {
        storeDirectory.appending(path: "\(installationID).json")
    }

    func read(_ installationID: String) throws -> StoreFile? {
        let url = fileURL(installationID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let data = try Data(contentsOf: url)
        struct Header: Decodable { var schemaVersion: Int }
        let header = try Self.decoder.decode(Header.self, from: data)
        guard header.schemaVersion <= Self.schemaVersion else {
            throw InstallStoreError.unsupportedSchemaVersion(header.schemaVersion, file: url.lastPathComponent)
        }
        return try Self.decoder.decode(StoreFile.self, from: data)
    }

    /// Just the installation, skipping the add-on list, which `installations()` doesn't need.
    func readInstallation(_ installationID: String) throws -> Installation? {
        let url = fileURL(installationID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        struct Header: Decodable {
            var schemaVersion: Int
            var installation: Installation
        }
        let header = try Self.decoder.decode(Header.self, from: Data(contentsOf: url))
        guard header.schemaVersion <= Self.schemaVersion else {
            throw InstallStoreError.unsupportedSchemaVersion(header.schemaVersion, file: url.lastPathComponent)
        }
        return header.installation
    }

    private func write(_ file: StoreFile) throws {
        precondition(lockDepth > 0, "InstallStore writes must hold the lock")
        var file = file
        file.schemaVersion = Self.schemaVersion
        file.addons.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try Self.encoder.encode(file).write(to: fileURL(file.installation.id), options: .atomic)
    }

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: dateStyle) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO-8601 date: \(text)")
        }
        return decoder
    }()

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
    }
}

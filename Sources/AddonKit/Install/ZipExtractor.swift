import Foundation
import ZIPFoundation

/// Validates and extracts add-on zips (DESIGN.md §6.8 step 1).
///
/// A valid archive has only top-level folders (plus ignored `__MACOSX/` and `.DS_Store`
/// noise), at least one of which contains a `.toc`, and no entry that could escape the
/// destination (`..`, absolute paths, symlinks).
public enum ZipExtractor {
    /// Top-level folder names in `archive`, after full validation. Extracts nothing.
    public static func topLevelFolders(in archive: URL) throws -> [String] {
        try validate(openArchive(archive)).folders
    }

    /// Validates `archive`, then extracts it into `destination` (created if missing).
    /// Returns the top-level folder names, sorted.
    @discardableResult
    public static func extract(_ archive: URL, to destination: URL) throws -> [String] {
        let zip = try openArchive(archive)
        let plan = try validate(zip)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = destination.standardizedFileURL
        for item in plan.entries {
            let target = root.appending(path: item.relativePath, directoryHint: item.entry.type == .directory ? .isDirectory : .notDirectory)
            guard isContained(target, in: root) else {
                throw AddonError.unsafeArchivePath(item.entry.path)
            }
            do {
                if item.entry.type == .directory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    _ = try zip.extract(item.entry, to: target)
                }
            } catch {
                throw AddonError.invalidArchive("could not extract \(item.entry.path): \(error.localizedDescription)")
            }
        }
        return plan.folders
    }

    // MARK: - Validation

    struct PlannedEntry {
        var entry: Entry
        /// Normalised `/`-joined path with empty and `.` components removed.
        var relativePath: String
    }

    struct Plan {
        var entries: [PlannedEntry]
        var folders: [String]
    }

    static func openArchive(_ url: URL) throws -> Archive {
        do {
            return try Archive(url: url, accessMode: .read)
        } catch {
            throw AddonError.invalidArchive("\(url.lastPathComponent) is not a readable zip")
        }
    }

    static func validate(_ zip: Archive) throws -> Plan {
        var entries: [PlannedEntry] = []
        var folders: [String] = []
        var seenFolders = Set<String>()
        var foldersWithToc = Set<String>()

        for entry in zip {
            let raw = entry.path
            let components = try safeComponents(of: raw)
            guard let top = components.first else { continue }
            if top == "__MACOSX" || components.last == ".DS_Store" { continue }
            if entry.type == .symlink {
                throw AddonError.unsafeArchivePath(raw)
            }

            let isDirectory = entry.type == .directory
            if components.count == 1 && !isDirectory {
                throw AddonError.invalidArchive("stray top-level file \(top)")
            }
            if seenFolders.insert(top).inserted {
                folders.append(top)
            }
            if components.count == 2 && !isDirectory && components[1].lowercased().hasSuffix(".toc") {
                foldersWithToc.insert(top)
            }
            entries.append(PlannedEntry(entry: entry, relativePath: components.joined(separator: "/")))
        }

        guard !folders.isEmpty else {
            throw AddonError.invalidArchive("archive is empty")
        }
        guard !foldersWithToc.isEmpty else {
            throw AddonError.invalidArchive("no top-level folder contains a .toc file")
        }
        return Plan(entries: entries, folders: folders.sorted())
    }

    /// Splits an entry path into components, rejecting anything that could escape the root.
    static func safeComponents(of path: String) throws -> [String] {
        if path.hasPrefix("/") || path.hasPrefix("\\") || path.hasPrefix("~") {
            throw AddonError.unsafeArchivePath(path)
        }
        // Windows drive letters (`C:\…`, `C:/…`).
        if path.count >= 2, path[path.index(after: path.startIndex)] == ":" {
            throw AddonError.unsafeArchivePath(path)
        }
        if path.contains("\0") {
            throw AddonError.unsafeArchivePath(path)
        }
        // Treat backslashes as separators for the safety check only.
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        if parts.contains("..") {
            throw AddonError.unsafeArchivePath(path)
        }
        return path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
    }

    static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return url.standardizedFileURL.path(percentEncoded: false).hasPrefix(prefix)
    }
}

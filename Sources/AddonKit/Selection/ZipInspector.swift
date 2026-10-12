import Foundation
import ZIPFoundation

/// Outcome of checking a zip or add-on folder for flavor support (docs/features/release-selection.md).
public struct FlavorSupport: Sendable, Hashable {
    public var flavor: Flavor
    public var isSupported: Bool
    /// Top-level add-on folders found (`F` containing `F/F[suffix].toc`), sorted.
    public var addonFolders: [String]
    /// Path of the TOC that decided support, e.g. `BigWigs/BigWigs_Camelot.toc`.
    public var matchedToc: String?
    /// One-line explanation for reasoning trails.
    public var detail: String

    public init(flavor: Flavor, isSupported: Bool, addonFolders: [String], matchedToc: String?, detail: String) {
        self.flavor = flavor
        self.isSupported = isSupported
        self.addonFolders = addonFolders
        self.matchedToc = matchedToc
        self.detail = detail
    }
}

/// Decides whether a zip, or an add-on folder on disk, supports a flavor by looking at its TOC files.
public enum ZipInspector {
    /// TOCs larger than this are not read.
    static let maxTocSize = 1 << 20

    /// Inspects the zip at `zipURL`. Throws `AddonError.invalidArchive` if it can't be opened.
    public static func inspect(zipAt zipURL: URL, flavor: Flavor) throws -> FlavorSupport {
        try inspect(ZipListing(url: zipURL), flavor: flavor)
    }

    public static func supports(_ flavor: Flavor, zipAt zipURL: URL) throws -> Bool {
        try inspect(zipAt: zipURL, flavor: flavor).isSupported
    }

    /// Inspects an installed add-on folder, e.g. `…/Interface/AddOns/BigWigs`.
    public static func inspect(addonFolder: URL, flavor: Flavor) throws -> FlavorSupport {
        try inspect(FolderListing(folder: addonFolder), flavor: flavor)
    }

    /// False if the folder can't be read or has no matching TOC.
    public static func supports(_ flavor: Flavor, addonFolder: URL) -> Bool {
        (try? inspect(addonFolder: addonFolder, flavor: flavor).isSupported) ?? false
    }

    // MARK: - Shared logic

    static func inspect(_ listing: some FileListing, flavor: Flavor) throws -> FlavorSupport {
        let folders = addonFolders(in: listing.paths)
        let names = folders.keys.sorted()
        func result(_ supported: Bool, _ toc: String?, _ detail: String) -> FlavorSupport {
            FlavorSupport(flavor: flavor, isSupported: supported, addonFolders: names, matchedToc: toc, detail: detail)
        }
        guard !names.isEmpty else {
            return result(false, nil, "no add-on folders with a matching TOC")
        }

        // 1. A TOC specific to the flavor (`_Camelot`, `-Forever`) settles it.
        for name in names {
            if let toc = folders[name]!.first(where: { $0.file.isSpecific(to: flavor) }) {
                return result(true, toc.path, "\(toc.path) is \(flavor.rawValue)-specific")
            }
        }

        // 2. Otherwise the TOC the client would load: the first shared family TOC in the
        //    flavor's order (`_Mainline`, `_Classic`) whose interface is in range, else the base one.
        var rejected: [String] = []
        for name in names {
            guard let loaded = try loadedToc(folders[name]!, flavor: flavor, read: { Toc(parsing: try listing.read($0)) }) else { continue }
            if loaded.supported {
                let interface = loaded.toc.interfaces.first { flavor.rules.contains(interface: $0) }!
                return result(true, loaded.entry.path, "\(loaded.entry.path) lists interface \(interface)")
            }
            let interfaces = loaded.toc.interfaces.map(String.init).joined(separator: ", ")
            rejected.append("\(loaded.entry.path) [\(interfaces.isEmpty ? "no interface" : interfaces)]")
        }
        let why = rejected.isEmpty ? "no \(flavor.rawValue) or base TOC" : "no \(flavor.rawValue) interface in " + rejected.joined(separator: "; ")
        return result(false, nil, why)
    }

    /// The TOC the game client loads for `flavor` from one add-on folder's own TOCs: one with
    /// the flavor's own suffix (which settles support on its own), else the first shared TOC
    /// in the flavor's order, else the base TOC. A shared or base TOC supports the flavor only
    /// when its interface is in range; the client still loads a shared one ahead of the base.
    /// Nil when the folder has none of these.
    static func loadedToc(
        _ tocs: [TocEntry], flavor: Flavor, read: (String) throws -> Toc
    ) rethrows -> (entry: TocEntry, toc: Toc, supported: Bool)? {
        if let specific = tocs.first(where: { $0.file.isSpecific(to: flavor) }) {
            return (specific, try read(specific.path), true)
        }
        let shared = tocs.compactMap { toc in toc.file.sharedRank(for: flavor).map { (rank: $0, toc: toc) } }
            .min { $0.rank < $1.rank }?.toc
        guard let entry = shared ?? tocs.first(where: { $0.file.suffix == nil }) else { return nil }
        let parsed = try read(entry.path)
        return (entry, parsed, parsed.supports(flavor))
    }

    /// Every TOC of an add-on folder on disk, plus the one the client loads for `flavor`
    /// (docs/architecture/data-storage.md#reconcile). Unreadable TOCs are skipped.
    public static func readTocs(addonFolder: URL, flavor: Flavor) -> FolderTocs {
        guard let listing = try? FolderListing(folder: addonFolder) else { return FolderTocs() }
        let name = addonFolder.lastPathComponent
        let byFolder = addonFolders(in: listing.paths)
        var own = byFolder[name] ?? byFolder.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? []
        // A folder whose TOCs don't carry its name (renamed by hand) still has hints worth reading.
        if own.isEmpty {
            own = listing.paths.sorted().compactMap { path in
                let file = String(path.split(separator: "/").last ?? "")
                guard !file.hasPrefix("._"), let name = TocFileName(file) else { return nil }
                return TocEntry(path: path, file: name)
            }
        }
        var parsed: [String: Toc] = [:]
        for entry in own {
            if let data = try? listing.read(entry.path) { parsed[entry.path] = Toc(parsing: data) }
        }
        func file(_ path: String) -> String { String(path.split(separator: "/").last ?? Substring(path)) }
        let readable = own.filter { parsed[$0.path] != nil }
        let all = readable.map { FolderTocs.File(name: file($0.path), toc: parsed[$0.path]!) }
        guard let loaded = loadedToc(readable, flavor: flavor, read: { parsed[$0]! }) else {
            return FolderTocs(all: all, loaded: all.first, isLoaded: false, supportsFlavor: false)
        }
        return FolderTocs(
            all: all, loaded: FolderTocs.File(name: file(loaded.entry.path), toc: loaded.toc),
            isLoaded: true, supportsFlavor: loaded.supported
        )
    }

    struct TocEntry {
        var path: String
        var file: TocFileName
    }

    /// Folder name → its own TOCs (`F/F[suffix].toc`), ignoring `__MACOSX/` and AppleDouble files.
    static func addonFolders(in paths: [String]) -> [String: [TocEntry]] {
        var folders: [String: [TocEntry]] = [:]
        for raw in paths {
            let path = normalize(raw)
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let folder = String(parts[0]), file = String(parts[1])
            guard !folder.isEmpty, folder != "__MACOSX", !file.hasPrefix("._"),
                  let name = TocFileName(file),
                  name.addonName.caseInsensitiveCompare(folder) == .orderedSame else { continue }
            folders[folder, default: []].append(TocEntry(path: path, file: name))
        }
        for key in folders.keys { folders[key]!.sort { $0.path < $1.path } }
        return folders
    }

    static func normalize(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }
}

/// "List of paths + read a file", so the same check runs on zips and on folders.
protocol FileListing {
    var paths: [String] { get }
    func read(_ path: String) throws -> Data
}

struct ZipListing: FileListing {
    let archive: Archive
    let paths: [String]

    init(url: URL) throws {
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw AddonError.invalidArchive("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        paths = archive.filter { $0.type == .file }.map(\.path)
    }

    func read(_ path: String) throws -> Data {
        guard let entry = archive.first(where: { ZipInspector.normalize($0.path) == path }) else {
            throw AddonError.invalidArchive("missing \(path)")
        }
        guard entry.uncompressedSize <= UInt64(ZipInspector.maxTocSize) else {
            throw AddonError.invalidArchive("\(path) is too large")
        }
        var data = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
        } catch {
            throw AddonError.invalidArchive("can't read \(path): \(error.localizedDescription)")
        }
        return data
    }
}

/// Presents an add-on folder on disk as `Folder/<file>` paths for its direct children.
struct FolderListing: FileListing {
    let parent: URL
    let paths: [String]

    init(folder: URL) throws {
        parent = folder.deletingLastPathComponent()
        let name = folder.lastPathComponent
        let children = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        paths = children.map { "\(name)/\($0)" }
    }

    func read(_ path: String) throws -> Data {
        let url = parent.appending(path: path, directoryHint: .notDirectory)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= ZipInspector.maxTocSize else { throw AddonError.invalidArchive("\(path) is too large") }
        return try Data(contentsOf: url)
    }
}

/// An add-on folder's TOCs as read from disk (`ZipInspector.readTocs`).
public struct FolderTocs: Sendable, Hashable {
    public struct File: Sendable, Hashable {
        /// e.g. `Questie_Camelot.toc`
        public var name: String
        public var toc: Toc

        public init(name: String, toc: Toc) {
            self.name = name
            self.toc = toc
        }
    }

    /// Every readable TOC, in name order.
    public var all: [File]
    /// The TOC the client loads for the flavor. When it loads none, the first TOC, for display.
    public var loaded: File?
    /// False when `loaded` is only a stand-in because the client loads no TOC from this folder.
    public var isLoaded: Bool
    /// The loaded TOC is for the installation's flavor.
    public var supportsFlavor: Bool

    public init(all: [File] = [], loaded: File? = nil, isLoaded: Bool = false, supportsFlavor: Bool = false) {
        self.all = all
        self.loaded = loaded
        self.isLoaded = isLoaded
        self.supportsFlavor = supportsFlavor
    }
}

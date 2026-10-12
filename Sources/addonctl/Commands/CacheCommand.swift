import AddonKit
import ArgumentParser
import Foundation

struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "Show or clear cached downloads and the metadata database.",
        discussion: """
            Downloads and the app's screenshot cache live in Caches. The catalogue, Forever verdicts, details and refresh state \
            live in metadata.sqlite in Application Support, shared with the app.
            """,
        subcommands: [Info.self, Clear.self],
        defaultSubcommand: Info.self
    )

    struct Entry: Encodable, Equatable {
        var name: String
        var path: String
        var files: Int
        var bytes: Int64
    }

    struct Output: Encodable {
        /// The Caches folder.
        var directory: String
        var metadataDatabase: String
        var entries: [Entry]
        var totalBytes: Int64
    }

    /// Sizes of the Caches folder's parts: downloads, release.json files, the app's
    /// screenshot cache, files older versions left behind, everything else.
    static func cacheUsage(of directories: AppDirectories) -> [Entry] {
        let fm = FileManager.default
        let root = directories.caches
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let labels: [String: String] = [
            "downloads": "Downloaded archives",
            "github": "GitHub release.json files",
            "screenshots": "Screenshot images",
            CatalogueSource.cacheFileName: "Old catalogue cache (unused)",
            SupportCache.fileName: "Old support cache (unused)",
        ]
        var entries: [Entry] = []
        var other = Entry(name: "Other", path: root.path(percentEncoded: false), files: 0, bytes: 0)
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let (files, bytes) = size(of: item)
            if let label = labels[item.lastPathComponent] {
                entries.append(Entry(name: label, path: item.path(percentEncoded: false), files: files, bytes: bytes))
            } else {
                other.files += files
                other.bytes += bytes
            }
        }
        if other.files > 0 { entries.append(other) }
        return entries
    }

    /// `metadata.sqlite` and its write-ahead log, when they exist.
    static func metadataUsage(of directories: AppDirectories) -> [Entry] {
        [
            ("Metadata database", MetadataInfo.databaseURL(directories)),
            ("Metadata write-ahead log", MetadataInfo.walURL(directories)),
        ].compactMap { name, url in
            let (files, bytes) = size(of: url)
            return files == 0 ? nil : Entry(name: name, path: url.path(percentEncoded: false), files: files, bytes: bytes)
        }
    }

    static func size(of url: URL) -> (files: Int, bytes: Int64) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        func bytes(_ url: URL) -> Int64 {
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else { return (0, 0) }
        guard isDirectory.boolValue else { return (1, bytes(url)) }
        var files = 0
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let file = enumerator?.nextObject() as? URL {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files += 1
                total += bytes(file)
            }
        }
        return (files, total)
    }

    /// Deletes everything in the Caches folder. The metadata database isn't in it.
    static func clearCacheFolder(_ directories: AppDirectories) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directories.caches.path(percentEncoded: false)) else { return }
        for item in try fm.contentsOfDirectory(at: directories.caches, includingPropertiesForKeys: nil) {
            try fm.removeItem(at: item)
        }
    }

    struct Info: ContextCommand {
        static let configuration = CommandConfiguration(commandName: "info", abstract: "Show cache and metadata database sizes.")

        @OptionGroup var global: GlobalOptions

        func run(_ context: CLIContext) async throws {
            let directories = context.directories
            let entries = CacheCommand.cacheUsage(of: directories) + CacheCommand.metadataUsage(of: directories)
            let total = entries.reduce(0) { $0 + $1.bytes }
            let databasePath = MetadataInfo.databaseURL(directories).path(percentEncoded: false)
            if context.json {
                try context.emit(Output(
                    directory: directories.caches.path(percentEncoded: false), metadataDatabase: databasePath,
                    entries: entries, totalBytes: total))
                return
            }
            context.print(context.style.dim(directories.caches.path(percentEncoded: false)))
            context.print(context.style.dim(databasePath))
            guard !entries.isEmpty else {
                context.print("The cache is empty.")
                return
            }
            let rows = entries.map { [$0.name, "\($0.files) file\($0.files == 1 ? "" : "s")", Format.bytes($0.bytes)] }
                + [[context.style.bold("Total"), "", context.style.bold(Format.bytes(total))]]
            context.print(Table(headers: ["CACHE", "FILES", "SIZE"], rows: rows).render(style: context.style))
        }
    }

    struct Clear: ContextCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear",
            abstract: "Delete cached downloads. With --metadata, also empty the metadata database."
        )

        @OptionGroup var global: GlobalOptions

        @Flag(help: "Also empty metadata.sqlite (catalogue, Forever verdicts, details, refresh state). Rebuilding it uses the network.")
        var metadata = false

        func run(_ context: CLIContext) async throws {
            let directories = context.directories
            let cacheBytes = CacheCommand.cacheUsage(of: directories).reduce(0) { $0 + $1.bytes }
            guard try context.confirm("Clear \(Format.bytes(cacheBytes)) of cached downloads? Rollback needs them.", action: "cache clear") else {
                throw CLIError.cancelled
            }
            if metadata {
                let metadataBytes = CacheCommand.metadataUsage(of: directories).reduce(0) { $0 + $1.bytes }
                let question = "Also empty the metadata database (\(Format.bytes(metadataBytes)))? Search finds nothing until the catalogue is downloaded again."
                guard try context.confirm(question, action: "cache clear --metadata") else { throw CLIError.cancelled }
            }

            try CacheCommand.clearCacheFolder(directories)
            if metadata { try await MetadataInfo.clear(context.manager.database) }

            if context.json {
                let remaining = CacheCommand.cacheUsage(of: directories) + CacheCommand.metadataUsage(of: directories)
                try context.emit(Output(
                    directory: directories.caches.path(percentEncoded: false),
                    metadataDatabase: MetadataInfo.databaseURL(directories).path(percentEncoded: false),
                    entries: remaining, totalBytes: remaining.reduce(0) { $0 + $1.bytes }))
            } else {
                context.say("Cleared \(Format.bytes(cacheBytes)) of cached downloads.")
                if metadata { context.say("Emptied the metadata database. Run `addonctl refresh` to rebuild it.") }
            }
        }
    }
}

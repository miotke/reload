import AddonKit
import ArgumentParser
import Foundation

struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "Manage the download, catalogue and support caches.",
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
        var directory: String
        var entries: [Entry]
        var totalBytes: Int64
    }

    /// Sizes of the cache folder's parts: downloads, catalogue, support checks, everything else.
    static func usage(of directories: AppDirectories) -> [Entry] {
        let fm = FileManager.default
        let root = directories.caches
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let labels: [String: String] = [
            "downloads": "Downloaded archives",
            CatalogueSource.cacheFileName: "Catalogue",
            SupportCache.fileName: "Forever support checks",
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

    struct Info: ContextCommand {
        static let configuration = CommandConfiguration(commandName: "info", abstract: "Show cache sizes.")

        @OptionGroup var global: GlobalOptions

        func run(_ context: CLIContext) async throws {
            let entries = CacheCommand.usage(of: context.directories)
            let total = entries.reduce(0) { $0 + $1.bytes }
            if context.json {
                try context.emit(Output(directory: context.directories.caches.path(percentEncoded: false), entries: entries, totalBytes: total))
                return
            }
            context.print(context.style.dim(context.directories.caches.path(percentEncoded: false)))
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
        static let configuration = CommandConfiguration(commandName: "clear", abstract: "Delete cached downloads, the catalogue and support checks.")

        @OptionGroup var global: GlobalOptions

        func run(_ context: CLIContext) async throws {
            let before = CacheCommand.usage(of: context.directories).reduce(0) { $0 + $1.bytes }
            guard try context.confirm("Clear \(Format.bytes(before)) of caches? Rollback needs cached downloads.", action: "cache clear") else {
                throw CLIError.cancelled
            }
            try await context.manager.clearCaches()
            if context.json {
                try context.emit(Output(directory: context.directories.caches.path(percentEncoded: false), entries: [], totalBytes: 0))
            } else {
                context.say("Cleared \(Format.bytes(before)) of caches.")
            }
        }
    }
}

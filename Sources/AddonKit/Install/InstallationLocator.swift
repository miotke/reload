import CryptoKit
import Foundation

/// Finds WoW installations and works out their flavor (DESIGN.md §6.2).
/// Only reads the file system; never writes.
public struct InstallationLocator: Sendable {
    /// Returns paths of WoW `.app` bundles (each lives inside a flavor folder).
    public typealias AppFinder = @Sendable () async -> [URL]

    public static let wowBundleID = "com.blizzard.worldofwarcraft"
    public static let defaultBaseFolders = [URL(filePath: "/Applications/World of Warcraft", directoryHint: .isDirectory)]

    let baseFolders: [URL]
    let findApps: AppFinder

    /// - Parameters:
    ///   - baseFolders: `World of Warcraft` folders to scan for `_*_` flavor folders.
    ///   - findApps: Spotlight lookup of WoW `.app` bundles; defaults to `mdfind`.
    public init(baseFolders: [URL] = InstallationLocator.defaultBaseFolders, findApps: @escaping AppFinder = { await InstallationLocator.spotlightApps() }) {
        self.baseFolders = baseFolders
        self.findApps = findApps
    }

    // MARK: - Discovery

    /// Every installation found, sorted by root path. Folders whose flavor can't be
    /// worked out are skipped (the user can add them by hand).
    public func locate() async -> [Installation] {
        var roots: [URL] = []
        var wowFolders: [URL] = baseFolders
        for app in await findApps() {
            let root = app.deletingLastPathComponent()
            roots.append(root)
            wowFolders.append(root.deletingLastPathComponent())
        }
        for folder in wowFolders {
            roots.append(contentsOf: Self.flavorFolders(in: folder))
        }

        var seen = Set<String>()
        var result: [Installation] = []
        for root in roots {
            guard Self.isDirectory(root), let installation = try? makeInstallation(root: root) else { continue }
            if seen.insert(installation.id).inserted {
                result.append(installation)
            }
        }
        return result.sorted { $0.root.path < $1.root.path }
    }

    /// An installation from a folder the user picked: the flavor folder itself
    /// (`…/_classic_beta_`), its `Interface/AddOns`, or the `World of Warcraft` folder
    /// when it holds exactly one flavor folder.
    /// - Throws: `AddonError.installationNotFound` if no single installation matches.
    public func installation(at url: URL) throws -> Installation {
        let url = Self.resolve(url)
        guard Self.isDirectory(url) else { throw AddonError.installationNotFound(url.path) }

        let parts = url.pathComponents
        if parts.count >= 3,
           parts[parts.count - 1].caseInsensitiveCompare("AddOns") == .orderedSame,
           parts[parts.count - 2].caseInsensitiveCompare("Interface") == .orderedSame {
            return try makeInstallation(root: url.deletingLastPathComponent().deletingLastPathComponent())
        }
        if Self.isFlavorFolderName(url.lastPathComponent) || Self.looksLikeInstallationRoot(url) {
            return try makeInstallation(root: url)
        }
        let flavorFolders = Self.flavorFolders(in: url)
        guard flavorFolders.count == 1 else { throw AddonError.installationNotFound(url.path) }
        return try makeInstallation(root: flavorFolders[0])
    }

    /// Stable id for an installation root: first 16 hex chars of SHA-256 of its resolved path.
    public static func installationID(for root: URL) -> String {
        var path = resolve(root).path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // MARK: - Flavor detection

    func makeInstallation(root: URL) throws -> Installation {
        let root = Self.resolve(root)
        let subfolder = root.lastPathComponent
        let wowFolder = root.deletingLastPathComponent()

        let productCode = Self.productCode(forSubfolder: subfolder) ?? Self.flavorInfoProduct(in: root)
        var gameVersion: String?
        if let productCode, let info = try? BuildInfo(contentsOf: wowFolder.appending(path: ".build.info")) {
            gameVersion = info.version(forProduct: productCode)
        }
        let flavor = gameVersion.flatMap(Flavor.from(gameVersion:))
            ?? Self.flavor(forSubfolder: subfolder)
            ?? productCode.flatMap(Self.flavor(forProduct:))
        guard let flavor else { throw AddonError.installationNotFound(root.path) }
        return Installation(
            id: Self.installationID(for: root),
            root: root,
            flavor: flavor,
            productCode: productCode,
            gameVersion: gameVersion
        )
    }

    static func productCode(forSubfolder name: String) -> String? {
        for flavor in Flavor.allCases {
            if let code = flavor.rules.knownSubfolders.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value {
                return code
            }
        }
        return nil
    }

    static func flavor(forSubfolder name: String) -> Flavor? {
        Flavor.allCases.first { $0.rules.knownSubfolders.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
    }

    static func flavor(forProduct code: String) -> Flavor? {
        Flavor.allCases.first { $0.rules.knownSubfolders.values.contains(code) }
    }

    /// Product code from `<root>/.flavor.info` (a one-column BPSV file), if present.
    static func flavorInfoProduct(in root: URL) -> String? {
        guard let text = try? String(contentsOf: root.appending(path: ".flavor.info"), encoding: .utf8) else { return nil }
        return BuildInfo(parsing: text).rows.first?.values.first.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - File-system helpers

    /// `_*_` subfolders of `wowFolder` that contain `Interface/` or a `.app`.
    static func flavorFolders(in wowFolder: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: wowFolder.path(percentEncoded: false)) else { return [] }
        return names
            .filter(isFlavorFolderName)
            .sorted()
            .map { wowFolder.appending(path: $0, directoryHint: .isDirectory) }
            .filter { isDirectory($0) && looksLikeInstallationRoot($0) }
    }

    static func isFlavorFolderName(_ name: String) -> Bool {
        name.count > 2 && name.hasPrefix("_") && name.hasSuffix("_")
    }

    static func looksLikeInstallationRoot(_ url: URL) -> Bool {
        if isDirectory(url.appending(path: "Interface", directoryHint: .isDirectory)) { return true }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        return names.contains { $0.lowercased().hasSuffix(".app") && isDirectory(url.appending(path: $0, directoryHint: .isDirectory)) }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
    }

    static func resolve(_ url: URL) -> URL {
        URL(filePath: url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false), directoryHint: .isDirectory)
    }

    // MARK: - Spotlight

    /// Runs `mdfind` for WoW app bundles, giving up after `timeout` seconds.
    public static func spotlightApps(timeout: TimeInterval = 3) async -> [URL] {
        let output = await runProcess(
            URL(filePath: "/usr/bin/mdfind"),
            arguments: ["kMDItemCFBundleIdentifier == '\(wowBundleID)'"],
            timeout: timeout
        )
        return parseSpotlightOutput(output)
    }

    static func parseSpotlightOutput(_ output: String) -> [URL] {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") && $0.lowercased().hasSuffix(".app") }
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// Runs `executable` and returns its stdout, or whatever it printed before `timeout`.
    static func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval) async -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }

        // Terminating the process closes the pipe, which ends the read loop below.
        let pid = process.processIdentifier
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            kill(pid, SIGTERM)
        }
        defer { watchdog.cancel() }

        var output = Data()
        do {
            for try await byte in pipe.fileHandleForReading.bytes {
                output.append(byte)
            }
        } catch {
            // Keep whatever arrived before the read failed.
        }
        return String(decoding: output, as: UTF8.self)
    }
}

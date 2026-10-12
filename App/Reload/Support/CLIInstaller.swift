import Foundation

/// Installs the bundled `reload` (docs/app/cli-install.md) as a symlink, by default
/// `/usr/local/bin/reload` → `Reload.app/Contents/Helpers/reload`. A symlink rather
/// than a copy, so updating the app updates the tool.
///
/// Changing `/usr/local/bin` needs admin rights, so the shell commands go through
/// `runPrivileged` (an AppleScript administrator prompt in the app; a stub in tests).
nonisolated struct CLIInstaller {
    enum Status: Equatable {
        /// Nothing at `linkPath`.
        case notInstalled
        /// `linkPath` links to this app's helper.
        case installed
        /// `linkPath` links into another copy of Reload.app (offer Repair).
        case otherCopy(target: String)
        /// Something unrelated is at `linkPath`: a file, or a link elsewhere (nil target for a file).
        case foreign(target: String?)
    }

    enum Failure: Error, Equatable, LocalizedError {
        /// The user cancelled the administrator password prompt.
        case cancelled
        case helperMissing(String)
        /// `linkPath` holds something this app didn't install, so it won't be removed.
        case notOurs(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: "The administrator password prompt was cancelled."
            case .helperMissing(let path): "The command-line tool is missing from the app bundle (\(path))."
            case .notOurs(let path): "\(path) wasn't installed by Reload, so it was left alone."
            case .failed(let message): message
            }
        }
    }

    static let defaultLinkPath = "/usr/local/bin/reload"
    static let appBundleName = "Reload.app"

    var linkPath: String
    var helperPath: String
    /// Runs a `/bin/sh` command line with administrator privileges.
    var runPrivileged: @Sendable (String) throws -> Void

    init(linkPath: String = CLIInstaller.defaultLinkPath, helperPath: String, runPrivileged: @escaping @Sendable (String) throws -> Void) {
        self.linkPath = linkPath
        self.helperPath = helperPath
        self.runPrivileged = runPrivileged
    }

    /// The helper inside the running app, installed with an AppleScript admin prompt.
    static func forRunningApp(bundle: Bundle = .main) -> CLIInstaller {
        let helper = bundle.bundleURL.appending(path: "Contents/Helpers/reload", directoryHint: .notDirectory)
        return CLIInstaller(helperPath: helper.path(percentEncoded: false), runPrivileged: AdministratorScript.run)
    }

    var helperExists: Bool { FileManager.default.isExecutableFile(atPath: helperPath) }

    // MARK: Status

    func status() -> Status {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: linkPath)) != nil else { return .notInstalled }
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: linkPath) else {
            return .foreign(target: nil)
        }
        let target = Self.absolute(destination, relativeTo: (linkPath as NSString).deletingLastPathComponent)
        if Self.samePath(target, helperPath) { return .installed }
        if Self.isReloadHelper(target) { return .otherCopy(target: target) }
        return .foreign(target: target)
    }

    /// True when `path` is inside an app bundle named Reload.app.
    static func isReloadHelper(_ path: String) -> Bool {
        URL(filePath: path).pathComponents.contains(appBundleName)
    }

    // MARK: Install / uninstall

    /// Creates (or repairs, or replaces) the link. Throws `Failure.cancelled` if the user
    /// dismisses the password prompt.
    func install() throws {
        guard helperExists else { throw Failure.helperMissing(helperPath) }
        try runPrivileged(installCommand)
        guard status() == .installed else {
            throw Failure.failed("Couldn't create the link at \(linkPath).")
        }
    }

    /// Removes the link, but only if it points into a Reload app bundle.
    func uninstall() throws {
        switch status() {
        case .notInstalled:
            return
        case .foreign:
            throw Failure.notOurs(linkPath)
        case .installed, .otherCopy:
            try runPrivileged(uninstallCommand)
            if status() != .notInstalled {
                throw Failure.failed("Couldn't remove \(linkPath).")
            }
        }
    }

    var installCommand: String {
        let directory = (linkPath as NSString).deletingLastPathComponent
        return "mkdir -p \(Self.shellQuote(directory)) && ln -sfn \(Self.shellQuote(helperPath)) \(Self.shellQuote(linkPath))"
    }

    /// `rm` only a symlink, never a real file or directory.
    var uninstallCommand: String {
        let link = Self.shellQuote(linkPath)
        return "if [ -L \(link) ]; then rm -f \(link); fi"
    }

    // MARK: Helpers

    /// Single-quotes `value` for `/bin/sh`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacing("'", with: "'\\''") + "'"
    }

    private static func absolute(_ path: String, relativeTo directory: String) -> String {
        let full = path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
        return (full as NSString).standardizingPath
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        let resolve = { (path: String) in URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false) }
        return resolve(a) == resolve(b)
    }
}

/// Runs shell commands as root through `do shell script … with administrator privileges`,
/// which shows the standard macOS password prompt. Uses `/usr/bin/osascript` rather than
/// `NSAppleScript` so it can run off the main thread; blocks the calling thread until the
/// prompt is answered.
nonisolated enum AdministratorScript {
    /// AppleScript's "User canceled." error.
    static let userCancelledCode = -128

    static func run(_ command: String) throws {
        let source = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CLIInstaller.Failure.failed("Couldn't run the installer script: \(error.localizedDescription)")
        }
        let errorOutput = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        // osascript reports e.g. "0:47: execution error: User canceled. (-128)".
        if errorOutput.contains("(\(userCancelledCode))") {
            throw CLIInstaller.Failure.cancelled
        }
        let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        throw CLIInstaller.Failure.failed(message.isEmpty ? "The installer script failed." : message)
    }

    /// Escapes `value` for use inside an AppleScript string literal.
    static func appleScriptEscape(_ value: String) -> String {
        value.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
    }
}

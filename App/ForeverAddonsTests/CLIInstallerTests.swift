import Foundation
import Testing

/// `CLIInstaller` against a temp folder, with the privileged runner replaced by a plain,
/// unprivileged `/bin/sh -c` (or a stub). Nothing touches `/usr/local/bin`.
@Suite struct CLIInstallerTests {
    let root: URL
    let helper: String
    let link: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "CLIInstallerTests-\(UUID().uuidString)/it's a \"test\"", directoryHint: .isDirectory)
        helper = try Self.makeHelper(in: root.appending(path: "Apps/ForeverAddons.app"))
        link = root.appending(path: "bin/addonctl").path(percentEncoded: false)
    }

    static func makeHelper(in app: URL) throws -> String {
        let helpers = app.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let path = helpers.appending(path: "addonctl").path(percentEncoded: false)
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        return path
    }

    /// Runs the command unprivileged and records it.
    final class Shell {
        var commands: [String] = []
        func run(_ command: String) throws {
            commands.append(command)
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-c", command]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { throw CLIInstaller.Failure.failed("exit \(process.terminationStatus)") }
        }
    }

    func makeInstaller(_ shell: Shell, helper: String? = nil) -> CLIInstaller {
        CLIInstaller(linkPath: link, helperPath: helper ?? self.helper, runPrivileged: shell.run)
    }

    @Test func installCreatesSymlinkAndUninstallRemovesIt() throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let shell = Shell()
        let installer = makeInstaller(shell)
        #expect(installer.status() == .notInstalled)

        try installer.install()
        #expect(installer.status() == .installed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == helper)
        // The helper is still a separate file; only a link was created.
        #expect(FileManager.default.isExecutableFile(atPath: helper))

        try installer.uninstall()
        #expect(installer.status() == .notInstalled)
        #expect(shell.commands.count == 2)
    }

    @Test func linkToAnotherAppCopyCanBeRepairedAndRemoved() throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let other = try Self.makeHelper(in: root.appending(path: "Downloads/ForeverAddons.app"))
        let shell = Shell()
        try makeInstaller(shell, helper: other).install()

        let installer = makeInstaller(shell)
        #expect(installer.status() == .otherCopy(target: other))
        try installer.install()
        #expect(installer.status() == .installed)

        try makeInstaller(shell, helper: other).uninstall()
        #expect(installer.status() == .notInstalled)
    }

    @Test func leavesForeignFilesAlone() throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let shell = Shell()
        let installer = makeInstaller(shell)
        try FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/bin/ls")

        #expect(installer.status() == .foreign(target: "/bin/ls"))
        #expect(throws: CLIInstaller.Failure.notOurs(link)) { try installer.uninstall() }

        try FileManager.default.removeItem(atPath: link)
        FileManager.default.createFile(atPath: link, contents: Data())
        #expect(installer.status() == .foreign(target: nil))
        #expect(throws: CLIInstaller.Failure.notOurs(link)) { try installer.uninstall() }
        #expect(shell.commands.isEmpty)
    }

    @Test func relativeLinkIsResolvedAgainstItsFolder() throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "../Apps/ForeverAddons.app/Contents/Helpers/addonctl")
        #expect(makeInstaller(Shell()).status() == .installed)
    }

    @Test func cancelledPromptIsReported() {
        let installer = CLIInstaller(linkPath: link, helperPath: helper) { _ in throw CLIInstaller.Failure.cancelled }
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(throws: CLIInstaller.Failure.cancelled) { try installer.install() }
        #expect(installer.status() == .notInstalled)
    }

    @Test func missingHelperIsNotInstalled() {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let shell = Shell()
        let installer = makeInstaller(shell, helper: "/nonexistent/ForeverAddons.app/Contents/Helpers/addonctl")
        #expect(throws: CLIInstaller.Failure.self) { try installer.install() }
        #expect(shell.commands.isEmpty)
    }

    @Test func quoting() {
        #expect(CLIInstaller.shellQuote("/a b/it's") == #"'/a b/it'\''s'"#)
        #expect(AdministratorScript.appleScriptEscape(#"echo "a\b""#) == #"echo \"a\\b\""#)
        #expect(CLIInstaller.isForeverAddonsHelper("/Applications/ForeverAddons.app/Contents/Helpers/addonctl"))
        #expect(!CLIInstaller.isForeverAddonsHelper("/opt/homebrew/bin/addonctl"))
    }
}

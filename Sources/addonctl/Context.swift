import AddonKit
import ArgumentParser
import Foundation

/// Options every command accepts (docs/cli/commands.md).
struct GlobalOptions: ParsableArguments {
    @Option(name: [.customShort("I"), .customLong("install")], help: ArgumentHelp("Installation to use: an id from `addonctl installs`, or a path.", valueName: "id|path"))
    var install: String?

    @Flag(help: "Machine-readable output on stdout; no prompts or colour.")
    var json = false

    @Flag(name: [.short, .long], help: "Assume yes for confirmations.")
    var yes = false

    @Flag(name: [.short, .long], help: "Print only essential output.")
    var quiet = false

    @Flag(name: [.short, .long], help: "Print extra detail.")
    var verbose = false

    @Flag(name: .customLong("no-color"), help: "Disable colour (NO_COLOR is honoured too).")
    var noColor = false
}

/// Everything a command needs at run time: output, prompts, config and the manager.
struct CLIContext: Sendable {
    var json: Bool
    var yes: Bool
    var quiet: Bool
    var verbose: Bool
    var installFlag: String?
    var environment: [String: String]
    var console: Console
    /// Styling for stdout.
    var style: Style
    /// Styling for stderr (progress, prompts, warnings).
    var errStyle: Style
    var directories: AppDirectories
    var config: ConfigStore
    var manager: AddonManager
    var keychain: KeychainStore

    init(options: GlobalOptions, environment: [String: String] = ProcessInfo.processInfo.environment, console: Console = .detect()) {
        json = options.json
        yes = options.yes
        quiet = options.quiet
        verbose = options.verbose && !options.quiet
        installFlag = options.install
        self.environment = environment
        self.console = console
        style = Style(enabled: Style.colorEnabled(isTTY: console.stdoutIsTTY, noColorFlag: options.noColor, json: options.json, environment: environment))
        errStyle = Style(enabled: Style.colorEnabled(isTTY: console.stderrIsTTY, noColorFlag: options.noColor, json: options.json, environment: environment))
        directories = CLIEnvironment.directories(environment)
        config = ConfigStore(directories: directories)
        keychain = KeychainStore()
        manager = AddonManager(directories: directories, locator: CLIEnvironment.locator(environment), keychain: keychain, environment: environment)
    }

    /// Prompts are allowed only on a terminal and never with `--json`.
    var interactive: Bool { !json && console.stdinIsTTY && console.stderrIsTTY }
    /// Live progress bars and spinners on stderr.
    var showsProgress: Bool { !json && !quiet && console.stderrIsTTY }
    var prompter: Prompter { Prompter(style: errStyle) }

    // MARK: Output

    /// Normal output on stdout (suppressed by `--quiet` and `--json`).
    func say(_ text: String) {
        guard !quiet, !json else { return }
        console.out(text)
    }

    /// Essential output on stdout (suppressed only by `--json`).
    func print(_ text: String) {
        guard !json else { return }
        console.out(text)
    }

    func detail(_ text: String) {
        guard verbose, !json else { return }
        console.err(errStyle.dim(text))
    }

    /// A short aside on stderr, e.g. that GitHub was asked too (suppressed by `--quiet` and `--json`).
    func note(_ text: String) {
        guard !quiet, !json else { return }
        console.err(errStyle.dim(text))
    }

    func warn(_ text: String) {
        guard !json else { return }
        console.err(errStyle.yellow("warning: ") + text)
    }

    /// Reports one failed item of a batch. A single-item batch skips this: its error is
    /// rethrown and printed once at exit.
    func itemError(_ name: String, _ error: any Error, batchSize: Int) {
        guard !json, batchSize > 1 else { return }
        console.err(errStyle.red("error: ") + "\(name): " + ExitStatus.message(for: error))
    }

    /// Prints the `--json` document. Call only when `json` is set.
    func emit<Payload: Encodable>(_ payload: Payload) throws {
        console.out(try JSONOutput.document(payload))
    }

    func confirm(_ question: String, action: String, defaultYes: Bool = false) throws -> Bool {
        if yes { return true }
        guard interactive else { throw CLIError.confirmationRequired(action) }
        return prompter.confirm(question, defaultYes: defaultYes)
    }

    /// After changing files: tell the user to `/reload` if the game is running.
    func noteIfGameRunning(changed: Int) {
        guard changed > 0, !json, !quiet, WoWProcess.isRunning() else { return }
        console.out(style.yellow("WoW is running; type /reload to load the changes."))
    }

    // MARK: Installation & refs

    func installations() async throws -> [Installation] {
        try await manager.installations()
    }

    /// The installation this command acts on (flag → config → only install → ask).
    func installation() async throws -> Installation {
        let all = try await installations()
        let locator = CLIEnvironment.locator(environment)
        let outcome = try InstallationSelection.select(
            flag: installFlag,
            configDefault: config.load().defaultInstall,
            installations: all,
            pathLookup: { try locator.installation(at: $0) }
        )
        switch outcome {
        case .selected(let installation):
            return installation
        case .ambiguous(let candidates):
            guard interactive else { throw CLIError.ambiguousInstallation(candidates) }
            let options = candidates.map { "\($0.id)  \($0.root.path(percentEncoded: false))" }
            guard let index = prompter.choose("Which installation?", options: options) else { throw CLIError.cancelled }
            return candidates[index]
        }
    }

    /// Like `installation()`, but read-only commands (search, resolve, info) still work with
    /// no WoW install at all by using a placeholder Forever installation.
    func installationOrPlaceholder() async throws -> Installation {
        do {
            return try await installation()
        } catch CLIError.noInstallations {
            return Installation(id: "none", root: directories.applicationSupport.appending(path: "no-installation"), flavor: .forever)
        }
    }

    /// Turns a `<ref>` argument into one `AddonRef`, asking on a terminal when it's ambiguous.
    func ref(for input: String, in installation: Installation) async throws -> AddonRef {
        let candidates = try await manager.lookup(input, in: installation)
        switch RefSelection.decide(candidates) {
        case .single(let ref):
            return ref
        case .none:
            throw CLIError.referenceNotFound(input)
        case .ambiguous(let refs):
            guard interactive else { throw CLIError.ambiguousReference(input, refs) }
            guard let index = prompter.choose("\"\(input)\" matches several add-ons:", options: refs.map(Format.ref)) else {
                throw CLIError.cancelled
            }
            return refs[index]
        }
    }

    /// The installed add-on for `ref`, if any.
    func installedAddon(_ ref: AddonRef, in installation: Installation) async throws -> InstalledAddon? {
        try await manager.installedAddons(in: installation).first { $0.id == ref }
    }
}

/// A command that runs with a `CLIContext`.
protocol ContextCommand: AsyncParsableCommand {
    var global: GlobalOptions { get }
    func run(_ context: CLIContext) async throws
}

extension ContextCommand {
    mutating func run() async throws {
        try await run(CLIContext(options: global))
    }
}

/// `<ref>` argument completion: installed add-on names.
extension CompletionKind {
    static var installedAddons: CompletionKind { .custom(RefCompletion.candidates) }
}

/// `stable|prerelease` argument. A CLI-local type avoids a retroactive conformance on `Channel`.
enum ChannelArgument: String, CaseIterable, ExpressibleByArgument {
    case stable, prerelease
    var channel: Channel { Channel(rawValue: rawValue) ?? .stable }
}

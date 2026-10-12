import Foundation
import Synchronization

/// ANSI styling. Every method returns its input unchanged when colour is off.
struct Style: Sendable, Equatable {
    var enabled: Bool

    static let plain = Style(enabled: false)

    /// Colour is used only on a terminal, never with `--json`, `--no-color`, a non-empty
    /// `NO_COLOR` (https://no-color.org) or `TERM=dumb`.
    static func colorEnabled(isTTY: Bool, noColorFlag: Bool, json: Bool, environment: [String: String]) -> Bool {
        guard isTTY, !noColorFlag, !json else { return false }
        if let value = environment["NO_COLOR"], !value.isEmpty { return false }
        if environment["TERM"] == "dumb" { return false }
        return true
    }

    func apply(_ code: String, _ text: String) -> String {
        enabled && !text.isEmpty ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    func bold(_ s: String) -> String { apply("1", s) }
    func dim(_ s: String) -> String { apply("2", s) }
    func red(_ s: String) -> String { apply("31", s) }
    func green(_ s: String) -> String { apply("32", s) }
    func yellow(_ s: String) -> String { apply("33", s) }
    func blue(_ s: String) -> String { apply("34", s) }
    func cyan(_ s: String) -> String { apply("36", s) }

    /// Removes ANSI escape sequences.
    static func strip(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return s.replacing(/\x{1B}\[[0-9;?]*[A-Za-z]/, with: "")
    }

    /// Visible width in terminal columns (escape sequences don't count).
    static func width(_ s: String) -> Int {
        strip(s).count
    }
}

/// Where output goes. Writes are unbuffered so stdout and stderr interleave correctly.
struct Console: Sendable {
    var stdinIsTTY: Bool
    var stdoutIsTTY: Bool
    var stderrIsTTY: Bool

    static func detect() -> Console {
        Console(stdinIsTTY: isatty(STDIN_FILENO) != 0, stdoutIsTTY: isatty(STDOUT_FILENO) != 0, stderrIsTTY: isatty(STDERR_FILENO) != 0)
    }

    /// Writes `text` plus a newline to stdout.
    func out(_ text: String = "") { Self.write(text + "\n", to: .standardOutput) }
    /// Writes `text` plus a newline to stderr.
    func err(_ text: String = "") { Self.write(text + "\n", to: .standardError) }

    static func write(_ text: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// Terminal width of stderr, falling back to 80.
    static func columns() -> Int {
        var size = winsize()
        if ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
        return 80
    }
}

/// Reads answers from stdin. Questions go to stderr so stdout stays clean.
struct Prompter: Sendable {
    var style: Style
    /// Injected in tests.
    var readLine: @Sendable () -> String? = { Swift.readLine(strippingNewline: true) }

    func confirm(_ question: String, defaultYes: Bool = false) -> Bool {
        Console.write("\(question) \(defaultYes ? "[Y/n]" : "[y/N]") ", to: .standardError)
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        if answer.isEmpty { return defaultYes }
        return answer == "y" || answer == "yes"
    }

    /// Returns the index of the chosen option, or nil if the user gave up.
    func choose(_ question: String, options: [String]) -> Int? {
        Console.write("\(question)\n", to: .standardError)
        for (index, option) in options.enumerated() {
            Console.write("  \(style.bold(String(index + 1)))) \(option)\n", to: .standardError)
        }
        for _ in 0..<3 {
            Console.write("Choose 1-\(options.count) (Enter to cancel): ", to: .standardError)
            guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
            if let number = Int(line), (1...options.count).contains(number) { return number - 1 }
        }
        return nil
    }

    /// Reads a secret without echo when stdin is a terminal.
    static func readSecret(prompt: String, stdinIsTTY: Bool) -> String? {
        guard stdinIsTTY else {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        }
        Console.write(prompt, to: .standardError)
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var silent = original
        silent.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &silent)
        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            Console.write("\n", to: .standardError)
        }
        return Swift.readLine(strippingNewline: true)
    }
}

/// A one-line spinner on stderr. Does nothing unless `enabled`.
final class Spinner: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func start(_ message: String) {
        guard enabled else { return }
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let newTask = Task.detached {
            var index = 0
            while !Task.isCancelled {
                Console.write("\r\u{1B}[2K\(frames[index % frames.count]) \(message)", to: .standardError)
                index += 1
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        task.withLock { $0 = newTask }
    }

    func stop() {
        guard enabled else { return }
        let running = task.withLock { task in
            defer { task = nil }
            return task
        }
        running?.cancel()
        Console.write("\r\u{1B}[2K", to: .standardError)
    }
}

/// Live progress rows on stderr, one per add-on, redrawn in place. A no-op unless `live`.
final class ProgressBoard: Sendable {
    struct Row: Sendable {
        var key: String
        var name: String
        var detail: String
        var fraction: Double?
        var status: String
    }

    private struct State {
        var rows: [Row] = []
        var drawnLines = 0
        var lastDraw = ContinuousClock.now - .seconds(1)
    }

    let live: Bool
    let style: Style
    private let state = Mutex(State())

    init(live: Bool, style: Style) {
        self.live = live
        self.style = style
    }

    func add(key: String, name: String, detail: String = "", status: String = "queued") {
        state.withLock { state in
            guard !state.rows.contains(where: { $0.key == key }) else { return }
            state.rows.append(Row(key: key, name: name, detail: detail, fraction: nil, status: status))
        }
        redraw(force: true)
    }

    func update(key: String, fraction: Double? = nil, detail: String? = nil, status: String? = nil) {
        let structural = status != nil || detail != nil
        state.withLock { state in
            guard let index = state.rows.firstIndex(where: { $0.key == key }) else { return }
            if let fraction { state.rows[index].fraction = min(max(fraction, 0), 1) }
            if let detail { state.rows[index].detail = detail }
            if let status { state.rows[index].status = status }
        }
        redraw(force: structural)
    }

    /// Draws the final state. Rows stay on screen.
    func finish() {
        redraw(force: true)
    }

    private func redraw(force: Bool) {
        guard live else { return }
        let text: String? = state.withLock { state in
            let now = ContinuousClock.now
            guard force || now - state.lastDraw > .milliseconds(50) else { return nil }
            state.lastDraw = now
            var output = state.drawnLines > 0 ? "\u{1B}[\(state.drawnLines)A" : ""
            let nameWidth = state.rows.map { Style.width($0.name) }.max() ?? 0
            let detailWidth = state.rows.map { Style.width($0.detail) }.max() ?? 0
            for row in state.rows {
                output += "\r\u{1B}[2K" + Self.render(row, nameWidth: nameWidth, detailWidth: detailWidth, style: style) + "\n"
            }
            state.drawnLines = state.rows.count
            return output
        }
        if let text { Console.write(text, to: .standardError) }
    }

    static func render(_ row: Row, nameWidth: Int, detailWidth: Int, style: Style) -> String {
        var line = "  " + pad(row.name, to: nameWidth)
        if detailWidth > 0 { line += "  " + pad(row.detail, to: detailWidth) }
        if let fraction = row.fraction {
            line += "  " + bar(fraction, style: style)
        }
        line += "  " + row.status
        return line
    }

    static func bar(_ fraction: Double, width: Int = 20, style: Style) -> String {
        let filled = Int((fraction * Double(width)).rounded(.down))
        let done = String(repeating: "━", count: filled)
        let rest = String(repeating: "━", count: width - filled)
        return style.enabled ? style.green(done) + style.dim(rest) : done + String(repeating: "─", count: width - filled)
    }

    static func pad(_ s: String, to width: Int) -> String {
        s + String(repeating: " ", count: max(0, width - Style.width(s)))
    }
}

import Foundation

/// A block of a README or changelog. `Text` only renders inline Markdown, so blocks are
/// split out here, and each block's inline text is rendered while parsing (off the main actor).
nonisolated enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: InlineText)
    case paragraph(InlineText)
    /// `marker` is "•", "☐"/"☑" for task items, or the number ("1.") of an ordered item.
    case listItem(marker: String, depth: Int, text: InlineText)
    case code(String)
    case quote(InlineText)
    case table([[InlineText]])
    case rule

    /// The same block with its inline text rendered against `baseURL` (relative links).
    func rendered(baseURL: URL?) -> MarkdownBlock {
        switch self {
        case .heading(let level, let text): .heading(level: level, text: text.rendered(baseURL: baseURL))
        case .paragraph(let text): .paragraph(text.rendered(baseURL: baseURL))
        case .listItem(let marker, let depth, let text): .listItem(marker: marker, depth: depth, text: text.rendered(baseURL: baseURL))
        case .quote(let text): .quote(text.rendered(baseURL: baseURL))
        case .table(let rows): .table(rows.map { $0.map { $0.rendered(baseURL: baseURL) } })
        case .code, .rule: self
        }
    }
}

/// Inline Markdown (emphasis, code, links) with its `AttributedString` built once, so
/// `MarkdownView` never parses on the main actor. Equal when the source text is.
nonisolated struct InlineText: Hashable, Sendable, ExpressibleByStringLiteral {
    let source: String
    /// Nil until `rendered(baseURL:)`; views fall back to plain text.
    let attributed: AttributedString?

    init(_ source: String) {
        self.source = source
        attributed = nil
    }

    init(stringLiteral value: String) {
        self.init(value)
    }

    private init(source: String, attributed: AttributedString) {
        self.source = source
        self.attributed = attributed
    }

    func rendered(baseURL: URL?) -> InlineText {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: source, options: options, baseURL: baseURL)) ?? AttributedString(source)
        // READMEs are untrusted: a `file:`, `x-apple…` or app-scheme link would open
        // something on this Mac when clicked. Only web links stay clickable.
        for run in attributed.runs {
            if let link = run.link, !Self.isWebLink(link) { attributed[run.range].link = nil }
        }
        return InlineText(source: source, attributed: attributed)
    }

    static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    var display: AttributedString { attributed ?? AttributedString(source) }

    static func == (a: InlineText, b: InlineText) -> Bool { a.source == b.source }
    func hash(into hasher: inout Hasher) { hasher.combine(source) }
}

/// A small, forgiving block parser: readable output for typical add-on READMEs, not full
/// CommonMark. Images are dropped (the inspector shows them in its screenshot gallery) and
/// HTML tags are stripped, keeping their text.
nonisolated enum MarkdownParser {
    /// Blocks with plain inline text, as the tests compare them.
    static func blocks(from markdown: String) -> [MarkdownBlock] {
        var parser = State()
        let text = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacing(htmlComment, with: "")
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            parser.consume(String(line))
        }
        parser.finish()
        return parser.blocks
    }

    /// Blocks ready to display: inline Markdown rendered against `baseURL`. Call off the main actor.
    static func renderedBlocks(from markdown: String, baseURL: URL?) -> [MarkdownBlock] {
        blocks(from: markdown).map { $0.rendered(baseURL: baseURL) }
    }

    // MARK: Inline cleanup

    nonisolated(unsafe) private static let htmlComment = /<!--[\s\S]*?-->/
    nonisolated(unsafe) private static let image = /!\[[^\]]*\]\([^)]*\)|!\[[^\]]*\]\[[^\]]*\]/
    /// What's left of a linked badge (`[![badge](img)](link)`) once the image is gone.
    nonisolated(unsafe) private static let emptyLink = /\[\s*\]\([^)]*\)|\[\s*\]\[[^\]]*\]/
    nonisolated(unsafe) private static let htmlTag = /<\/?[A-Za-z][^>]*>/
    nonisolated(unsafe) private static let heading = /^(#{1,6})\s+(.*?)\s*#*\s*$/
    nonisolated(unsafe) private static let listItem = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/
    nonisolated(unsafe) private static let rule = /^\s{0,3}([-*_])(\s*\1){2,}\s*$/
    nonisolated(unsafe) private static let tableSeparator = /^\s*\|?[\s:|-]+\|?\s*$/

    static func stripInline(_ line: String) -> String {
        line.replacing(image, with: "")
            .replacing(htmlTag, with: "")
            .replacing(emptyLink, with: "")
    }

    // MARK: State machine

    private struct State {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]?
        var fence = ""

        mutating func consume(_ raw: String) {
            let trimmedRaw = raw.trimmingCharacters(in: .whitespaces)

            if code != nil {
                if trimmedRaw.hasPrefix(fence) {
                    blocks.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(raw)
                }
                return
            }
            if trimmedRaw.hasPrefix("```") || trimmedRaw.hasPrefix("~~~") {
                flush()
                fence = String(trimmedRaw.prefix(3))
                code = []
                return
            }

            let line = MarkdownParser.stripInline(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                return
            }

            // Setext headings: a paragraph underlined with === or ---.
            if !paragraph.isEmpty, trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
                blocks.append(.heading(level: trimmed.first == "=" ? 1 : 2, text: InlineText(paragraph.joined(separator: " "))))
                paragraph = []
                return
            }
            if line.wholeMatch(of: MarkdownParser.rule) != nil {
                flush()
                blocks.append(.rule)
                return
            }
            if let match = trimmed.wholeMatch(of: MarkdownParser.heading) {
                flush()
                let text = String(match.output.2)
                if !text.isEmpty { blocks.append(.heading(level: match.output.1.count, text: InlineText(text))) }
                return
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(String(trimmed.drop { $0 == ">" || $0 == " " }))
                return
            }
            if let match = line.wholeMatch(of: MarkdownParser.listItem) {
                flush()
                let indent = match.output.1.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                var marker = String(match.output.2)
                var text = String(match.output.3)
                if marker.count == 1 {
                    marker = "•"
                    if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) }
                    else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text.removeFirst(4) }
                } else {
                    marker = String(marker.dropLast()) + "."
                }
                blocks.append(.listItem(marker: marker, depth: min(indent / 2, 3), text: InlineText(text)))
                return
            }
            if trimmed.hasPrefix("|") {
                flush()
                if trimmed.wholeMatch(of: MarkdownParser.tableSeparator) != nil { return }
                var cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                    .map { InlineText($0.trimmingCharacters(in: .whitespaces)) }
                if cells.first?.source == "" { cells.removeFirst() }
                if cells.last?.source == "" { cells.removeLast() }
                if case .table(let rows) = blocks.last {
                    blocks[blocks.count - 1] = .table(rows + [cells])
                } else {
                    blocks.append(.table([cells]))
                }
                return
            }
            // An indented line right after a list item continues that item.
            if paragraph.isEmpty, quote.isEmpty, raw.first == " " || raw.first == "\t",
               case .listItem(let marker, let depth, let text) = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker: marker, depth: depth, text: InlineText(text.source + " " + trimmed))
                return
            }
            if !quote.isEmpty { flushQuote() }
            // Two trailing spaces or a backslash is a hard line break.
            if raw.hasSuffix("  ") || trimmed.hasSuffix("\\") {
                paragraph.append(String(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\\"))) + "\n")
            } else {
                paragraph.append(trimmed)
            }
        }

        mutating func finish() {
            if let code { blocks.append(.code(code.joined(separator: "\n"))) }
            code = nil
            flush()
        }

        private mutating func flush() {
            flushParagraph()
            flushQuote()
        }

        private mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.reduce(into: "") { result, line in
                if !result.isEmpty && !result.hasSuffix("\n") { result += " " }
                result += line
            }
            blocks.append(.paragraph(InlineText(text.trimmingCharacters(in: .newlines))))
            paragraph = []
        }

        private mutating func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(InlineText(quote.joined(separator: " "))))
            quote = []
        }
    }
}

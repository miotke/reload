import SwiftUI

/// Renders parsed Markdown blocks (READMEs, release notes). Readable rather than exact:
/// see `MarkdownParser` for what's supported.
struct MarkdownView: View, Equatable {
    var blocks: [MarkdownBlock]
    /// Resolves relative links, e.g. a README's `docs/setup.md`.
    var baseURL: URL?

    var body: some View {
        // Lazy: a long README builds only the blocks scrolled into view.
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            Text(inline(text))
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit().foregroundStyle(.secondary)
                Text(inline(text))
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.callout.monospaced())
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
                Text(inline(text)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                Text(inline(cell)).fontWeight(index == 0 ? .semibold : nil)
                            }
                        }
                        if index == 0 { Divider() }
                    }
                }
                .padding(.vertical, 2)
            }
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options, baseURL: baseURL)) ?? AttributedString(text)
    }
}

/// Release notes from a Markdown string, parsed off the main actor once per text.
struct MarkdownText: View {
    var markdown: String
    @State private var blocks: [MarkdownBlock]?

    init(markdown: String) {
        self.markdown = markdown
        _blocks = State(initialValue: MarkdownCache.cached(markdown))
    }

    var body: some View {
        Group {
            if let blocks { MarkdownView(blocks: blocks) } else { Color.clear.frame(height: 1) }
        }
        .task(id: markdown) { blocks = await MarkdownCache.blocks(for: markdown) }
    }
}

/// Parsed release notes, keyed by their text (the same notes show for every visit to a release).
@MainActor
enum MarkdownCache {
    private static var entries: [String: [MarkdownBlock]] = [:]

    static func cached(_ markdown: String) -> [MarkdownBlock]? { entries[markdown] }

    static func blocks(for markdown: String) async -> [MarkdownBlock] {
        if let cached = entries[markdown] { return cached }
        let blocks = await Task.detached(priority: .userInitiated) { MarkdownParser.blocks(from: markdown) }.value
        // Release notes are small; a crude cap keeps a long session from growing without bound.
        if entries.count > 200 { entries.removeAll() }
        entries[markdown] = blocks
        return blocks
    }
}

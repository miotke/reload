import Foundation

/// Finds screenshot-worthy images in a README (docs/features/details-and-screenshots.md). Pure; no I/O.
///
/// - Markdown inline images `![alt](url "title")`, reference images `![alt][id]` /
///   `![id][]` / `![id]` with their `[id]: url` definitions, and HTML `<img src>`.
/// - Results are absolute, de-duplicated and in document order. Relative paths resolve
///   against the README's folder on raw.githubusercontent.com; `github.com/…/blob/…` and
///   `…/raw/…` links become raw URLs.
/// - Dropped: badges (shields.io and friends, CI status images, anything with "badge" in its
///   path), SVGs (badges and logos, almost never screenshots), favicons and images an HTML
///   tag sizes at 64 px or less, and anything inside code blocks.
public enum ReadmeImages {
    /// Hosts that only serve badges, buttons and status images.
    static let badgeHosts: Set<String> = [
        "img.shields.io", "shields.io", "badgen.net", "flat.badgen.net", "badge.fury.io", "img.badgesize.io",
        "travis-ci.org", "travis-ci.com", "api.travis-ci.com", "api.travis-ci.org", "circleci.com", "dl.circleci.com",
        "ci.appveyor.com", "codecov.io", "coveralls.io", "app.codacy.com", "api.codacy.com", "sonarcloud.io",
        "badges.gitter.im", "cf.way2muchnoise.eu", "wakatime.com", "liberapay.com", "img.buymeacoffee.com",
        "cdn.buymeacoffee.com", "www.buymeacoffee.com", "cdn.ko-fi.com", "storage.ko-fi.com", "ko-fi.com",
        "www.paypalobjects.com", "c5.patreon.com", "img.cdn4dd.com", "github-readme-stats.vercel.app",
        "forthebadge.com", "badge.waffle.io", "david-dm.org", "snyk.io", "deepscan.io", "www.codefactor.io",
        "discordapp.com", "discord.com", "invidget.switchblade.xyz", "dcbadge.vercel.app", "dcbadge.limes.pink",
    ]

    /// Images at or below this many pixels (by an HTML width or height) are icons.
    static let iconSize = 64

    /// Image URLs in `markdown`, the README at `readmePath` in `owner/repo` at `ref`.
    public static func extract(from markdown: String, owner: String, repo: String, ref: String = "HEAD", readmePath: String = "README.md") -> [URL] {
        let root = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(ref)/")!
        let folder = (readmePath as NSString).deletingLastPathComponent
        let base = folder.isEmpty ? root : root.appending(path: folder + "/", directoryHint: .isDirectory)
        let text = stripCode(markdown)

        var found: [(position: Int, source: String, width: Int?, height: Int?)] = []
        let ns = text as NSString
        func groups(_ pattern: String, options: NSRegularExpression.Options = []) -> [[String?]] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
                (0..<match.numberOfRanges).map { i in
                    let range = match.range(at: i)
                    return range.location == NSNotFound ? nil : ns.substring(with: range)
                } + ["\(match.range.location)"]
            }
        }

        // Reference definitions: [id]: <url> "title"
        var definitions: [String: String] = [:]
        // CommonMark allows spaces inside <…>.
        for g in groups(#"^ {0,3}\[([^\]]+)\]:[ \t]*(?:<([^>\n]+)>|(\S+))"#, options: .anchorsMatchLines) {
            if let id = g[1], let url = g[2] ?? g[3] { definitions[id.lowercased()] = url }
        }

        // Inline: ![alt](url "title")
        for g in groups(#"!\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\s*\)"#) {
            if let src = g[1], let pos = Int(g.last!!) { found.append((pos, src, nil, nil)) }
        }
        // Reference: ![alt][id], ![id][], ![id]
        for g in groups(#"!\[([^\]]*)\](?:\[([^\]]*)\]|(?![\[(]))"#) {
            let id = (g[2].flatMap { $0.isEmpty ? nil : $0 } ?? g[1] ?? "").lowercased()
            if let src = definitions[id], let pos = Int(g.last!!) { found.append((pos, src, nil, nil)) }
        }
        // HTML: <img src="…" width="…">
        for g in groups(#"<img\b[^>]*>"#, options: .caseInsensitive) {
            guard let tag = g[0], let pos = Int(g.last!!), let src = attribute("src", in: tag) else { continue }
            found.append((pos, src, attribute("width", in: tag).flatMap(pixels), attribute("height", in: tag).flatMap(pixels)))
        }

        var seen = Set<String>()
        var out: [URL] = []
        for image in found.sorted(by: { $0.position < $1.position }) {
            if let w = image.width, w <= iconSize { continue }
            if let h = image.height, h <= iconSize { continue }
            guard let url = resolve(image.source, base: base, root: root), !isBadgeOrIcon(url) else { continue }
            if seen.insert(url.absoluteString).inserted { out.append(url) }
        }
        return out
    }

    /// Removes fenced code blocks, inline code and HTML comments, which may contain
    /// image syntax that isn't rendered.
    static func stripCode(_ text: String) -> String {
        var result = text
        for pattern in [#"(?ms)^ {0,3}(```|~~~).*?^ {0,3}\1"#, #"(?s)<!--.*?-->"#, #"`[^`\n]+`"#] {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return result
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for i in 1...3 {
            if let range = Range(match.range(at: i), in: tag) { return String(tag[range]) }
        }
        return nil
    }

    /// `"48"` or `"48px"` → 48; percentages and other units → nil.
    static func pixels(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        return Int(trimmed.hasSuffix("px") ? String(trimmed.dropLast(2)) : trimmed)
    }

    /// An absolute http(s) URL for `source`, or nil for `data:`, anchors and the like.
    static func resolve(_ source: String, base: URL, root: URL) -> URL? {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
        if text.hasPrefix("//") { text = "https:" + text }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: text) ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)) else { return nil }
            return rawGitHubURL(url) ?? url
        }
        if text.contains(":") && !text.hasPrefix("./") && !text.hasPrefix("../") {
            // Another scheme (data:, mailto:, …).
            if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") { return nil }
        }
        let relative = text.split(separator: "?", maxSplits: 1).first.map(String.init) ?? text
        let encoded = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
        if encoded.hasPrefix("/") {
            return URL(string: String(encoded.dropFirst()), relativeTo: root)?.absoluteURL
        }
        return URL(string: encoded, relativeTo: base)?.absoluteURL
    }

    /// `github.com/o/r/blob/<ref>/path` or `…/raw/<ref>/path` → raw.githubusercontent.com.
    static func rawGitHubURL(_ url: URL) -> URL? {
        guard let host = url.host()?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 5, parts[2] == "blob" || parts[2] == "raw" else { return nil }
        let path = ([parts[0], parts[1]] + parts[3...]).joined(separator: "/")
        return URL(string: "https://raw.githubusercontent.com/\(path)")
    }

    static func isBadgeOrIcon(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        if badgeHosts.contains(host) || host.hasSuffix(".shields.io") { return true }
        let path = url.path(percentEncoded: false).lowercased()
        let query = url.query()?.lowercased() ?? ""
        if path.hasSuffix(".svg") || query.contains("format=svg") { return true }
        if path.contains("badge") || path.contains("/shields/") || path.contains("favicon") { return true }
        // GitHub Actions status images: …/actions/workflows/x.yml/badge.svg (caught above) or ?branch=… on /workflows/.
        if host == "github.com", path.contains("/workflows/") { return true }
        // icon-16x16.png, logo_32x32.png
        if path.range(of: #"(^|[^0-9])(16|24|32|48|64)x(16|24|32|48|64)([^0-9]|$)"#, options: .regularExpression) != nil { return true }
        return false
    }
}

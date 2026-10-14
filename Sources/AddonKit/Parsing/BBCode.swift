import Foundation

/// WoWInterface descriptions and changelogs are forum BBCode. This turns the common tags
/// into Markdown and drops the rest (sizes, colours, fonts, alignment), keeping their text.
/// Pure; anything it doesn't recognise passes through unchanged.
enum BBCode {
    static func markdown(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n")
        let replacements: [(String, String)] = [
            (#"(?is)\[url=["']?([^\]"']+)["']?\](.*?)\[/url\]"#, "[$2]($1)"),
            (#"(?is)\[url\](.*?)\[/url\]"#, "<$1>"),
            (#"(?is)\[img\](.*?)\[/img\]"#, "![]($1)"),
            (#"(?is)\[b\](.*?)\[/b\]"#, "**$1**"),
            (#"(?is)\[i\](.*?)\[/i\]"#, "*$1*"),
            (#"(?is)\[s\](.*?)\[/s\]"#, "~~$1~~"),
            (#"(?is)\[code\](.*?)\[/code\]"#, "\n```\n$1\n```\n"),
            (#"(?is)\[quote(?:=[^\]]*)?\](.*?)\[/quote\]"#, "\n> $1\n"),
            (#"(?im)^[ \t]*\[\*\][ \t]*"#, "- "),
            (#"(?i)\[\*\]"#, "\n- "),
            (#"(?i)\[/?list(?:=[^\]]*)?\]"#, "\n"),
            (#"(?i)\[/?(?:u|size|color|font|center|left|right|indent|highlight|align)(?:=[^\]]*)?\]"#, ""),
        ]
        for (pattern, template) in replacements {
            s = s.replacing(try! Regex(pattern), with: { match in
                var out = template
                for i in stride(from: match.output.count - 1, through: 1, by: -1) {
                    out = out.replacingOccurrences(of: "$\(i)", with: match.output[i].substring.map(String.init) ?? "")
                }
                return out
            })
        }
        // Blank lines the removed tags left behind.
        s = s.replacing(try! Regex(#"\n{3,}"#), with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

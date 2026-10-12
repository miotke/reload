#!/usr/bin/env swift
// Checks that the docs stay in sync with the code. Run from the repo root before committing:
//
//     swift scripts/check-docs.swift
//
// Exits non-zero and lists every problem. Rules (see .claude/CLAUDE.md):
//   1. Every relative link in docs/ and README.md points at a file (and heading) that exists.
//   2. Every doc in docs/ is listed in docs/README.md, and is at most 150 lines.
//   3. Every `docs/...md` path mentioned in source comments exists.
//   4. The "Where things live" tables in docs/architecture/core.md (core + CLI) and
//      docs/app/project.md (app) only name paths that exist, and together cover every
//      Swift file under Sources/ and App/ForeverAddons/.

import Foundation

let fm = FileManager.default
let root = URL(filePath: fm.currentDirectoryPath)
var problems: [String] = []

func read(_ path: String) -> String? { try? String(contentsOf: root.appending(path: path), encoding: .utf8) }
func exists(_ path: String) -> Bool { fm.fileExists(atPath: root.appending(path: path).path(percentEncoded: false)) }

func files(under dir: String, ext: String) -> [String] {
    guard let e = fm.enumerator(atPath: root.appending(path: dir).path(percentEncoded: false)) else { return [] }
    return e.compactMap { $0 as? String }
        .filter { $0.hasSuffix(ext) && !$0.contains(".build/") && !$0.contains("DerivedData") }
        .map { "\(dir)/\($0)" }
        .sorted()
}

/// GitHub-style heading anchor.
func slug(_ heading: String) -> String {
    let lowered = heading.lowercased()
    let kept = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_" }
    return String(String.UnicodeScalarView(kept)).replacingOccurrences(of: " ", with: "-")
}

func anchors(in path: String) -> Set<String> {
    guard let text = read(path) else { return [] }
    var result = Set<String>()
    var inFence = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("```") { inFence.toggle(); continue }
        guard !inFence, line.hasPrefix("#") else { continue }
        // GitHub builds the anchor from the rendered text, so `[text](url)` counts as `text`.
        let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "`", with: "")
            .replacing(try! Regex(#"\[([^\]]*)\]\([^)]*\)"#)) { String($0.output[1].substring ?? "") }
        result.insert(slug(title))
    }
    return result
}

// MARK: 1 & 2. Links, index, sizes

let docs = files(under: "docs", ext: ".md")
let linkPattern = try! Regex(#"\]\(([^)\s]+)\)"#)
for doc in docs + ["README.md"] {
    guard let text = read(doc) else { continue }
    let dir = (doc as NSString).deletingLastPathComponent
    var inFence = false
    for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        if line.hasPrefix("```") { inFence.toggle(); continue }
        if inFence { continue }
        for match in line.matches(of: linkPattern) {
            let target = String(match.output[1].substring ?? "")
            if target.hasPrefix("http") || target.hasPrefix("mailto:") { continue }
            let parts = target.components(separatedBy: "#")
            let file = parts.first ?? ""
            let resolved = file.isEmpty ? doc : ((dir.isEmpty ? file : "\(dir)/\(file)") as NSString).standardizingPath
            if !exists(resolved) {
                problems.append("\(doc):\(number + 1): broken link → \(target)")
            } else if parts.count >= 2, resolved.hasSuffix(".md"), !anchors(in: resolved).contains(parts[1]) {
                problems.append("\(doc):\(number + 1): missing heading #\(parts[1]) in \(resolved)")
            }
        }
    }
}

let index = read("docs/README.md") ?? ""
for doc in docs where doc != "docs/README.md" {
    let relative = String(doc.dropFirst("docs/".count))
    if !index.contains("(\(relative))") && !doc.hasPrefix("docs/decisions/") {
        problems.append("\(doc): not listed in docs/README.md")
    }
    let lines = (read(doc) ?? "").split(separator: "\n", omittingEmptySubsequences: false).count
    if lines > 150 { problems.append("\(doc): \(lines) lines (max 150); split it") }
}
let decisionIndex = read("docs/decisions/README.md") ?? ""
for doc in docs where doc.hasPrefix("docs/decisions/") && doc != "docs/decisions/README.md" {
    let name = (doc as NSString).lastPathComponent
    if !decisionIndex.contains(name) { problems.append("\(doc): not listed in docs/decisions/README.md") }
}

// MARK: 3. Doc paths in source comments

// Tests are skipped: they contain example paths as test data.
let sources = files(under: "Sources", ext: ".swift") + files(under: "App/ForeverAddons", ext: ".swift")
let docPathPattern = try! Regex(#"docs/[a-z0-9/_-]+\.md"#)
for source in sources {
    guard let text = read(source) else { continue }
    for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
    where line.contains("//") {
        for match in line.matches(of: docPathPattern) where !exists(String(line[match.range])) {
            problems.append("\(source):\(number + 1): comment points at missing \(line[match.range])")
        }
    }
}

// MARK: 4. "Where things live" tables

func tablePaths(_ doc: String) -> [String]? {
    guard let text = read(doc), let start = text.range(of: "## Where things live") else { return nil }
    let section = text[start.upperBound...]
    let end = section.range(of: "\n## ")?.lowerBound ?? section.endIndex
    let pathPattern = try! Regex(#"`((?:Sources|App|Tests|Package\.swift)[^`]*)`"#)
    return section[..<end].matches(of: pathPattern).map { String($0.output[1].substring ?? "") }
}

var covered: [String] = []
for (doc, area) in [("docs/architecture/core.md", "core and CLI"), ("docs/app/project.md", "app")] {
    guard let paths = tablePaths(doc) else {
        problems.append("\(doc): missing \"## Where things live\" table (\(area))")
        continue
    }
    for path in paths {
        let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
        if !exists(clean) { problems.append("\(doc): Where things live names missing path \(path)") }
        covered.append(clean)
    }
}
if !covered.isEmpty {
    let mustCover = files(under: "Sources", ext: ".swift") + files(under: "App/ForeverAddons", ext: ".swift")
    for file in mustCover where !covered.contains(where: { file == $0 || file.hasPrefix($0 + "/") }) {
        problems.append("\(file): not in any Where things live table")
    }
}

// MARK: Report

if problems.isEmpty {
    print("docs check passed (\(docs.count) docs, \(sources.count) source files)")
} else {
    print(problems.joined(separator: "\n"))
    print("\n\(problems.count) problem(s). See .claude/CLAUDE.md → Documentation.")
    exit(1)
}

import Foundation

// MARK: - Text normalisation

/// Tokenisation and folding shared by every local search layer (DESIGN.md §7.2).
enum SearchText {
    static func fold(_ s: some StringProtocol) -> String {
        String(s).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// Words split on non-alphanumerics (original case preserved).
    static func words(_ s: some StringProtocol) -> [Substring] {
        let string = Substring(s)
        return string.split { !($0.isLetter || $0.isNumber) }
    }

    /// Splits `DeadlyBossMods` → Deadly/Boss/Mods, `DBMVoice` → DBM/Voice,
    /// `WeakAuras2` → Weak/Auras/2.
    static func camelParts(_ word: Substring) -> [Substring] {
        let chars = Array(word.indices)
        guard chars.count > 1 else { return [word] }
        var parts: [Substring] = []
        var start = word.startIndex
        for k in 1..<chars.count {
            let prev = word[chars[k - 1]], cur = word[chars[k]]
            let next: Character? = k + 1 < chars.count ? word[chars[k + 1]] : nil
            var boundary = false
            if prev.isLowercase && cur.isUppercase { boundary = true }
            else if prev.isUppercase && cur.isUppercase, let next, next.isLowercase { boundary = true }
            else if prev.isLetter && cur.isNumber { boundary = true }
            else if prev.isNumber && cur.isLetter { boundary = true }
            if boundary {
                parts.append(word[start..<chars[k]])
                start = chars[k]
            }
        }
        parts.append(word[start...])
        return parts
    }

    /// Folded tokens for a field: each whole word plus its camelCase parts.
    static func tokens(_ s: some StringProtocol) -> [String] {
        var out: [String] = []
        for word in words(s) {
            out.append(fold(word))
            let parts = camelParts(word)
            if parts.count > 1 { out.append(contentsOf: parts.map(fold)) }
        }
        return out
    }

    /// Folded, alphanumerics only: `"BigWigs_Classic"` → `"bigwigsclassic"`.
    static func key(_ s: some StringProtocol) -> String {
        words(s).map(fold).joined()
    }
}

// MARK: - Query plan

/// A parsed query with alias variants. Each variant is a list of folded words.
struct SearchPlan: Sendable {
    struct Variant: Sendable {
        var words: [String]
        var key: String
    }

    var variants: [Variant]

    init?(_ text: String, aliases: [String: [String]] = SearchAliases.aliases) {
        let words = SearchText.words(text).map(SearchText.fold)
        guard !words.isEmpty else { return nil }
        var variants = [Variant(words: words, key: words.joined())]
        if words.contains(where: { aliases[$0] != nil }) {
            let expanded = words.flatMap { aliases[$0] ?? [$0] }
            variants.append(Variant(words: expanded, key: expanded.joined()))
        }
        self.variants = variants
    }
}

/// Precomputed tokens for one searchable record.
struct SearchDocument: Sendable {
    /// Folded alphanumeric-only name, for exact / prefix tiers.
    var nameKey: String
    var nameTokens: [String]
    /// Owner, repo, description and any other searchable text.
    var otherTokens: [String]

    init(name: String, otherFields: [String?]) {
        nameKey = SearchText.key(name)
        var nameTokens = SearchText.tokens(name)
        if !nameTokens.contains(nameKey) { nameTokens.append(nameKey) }
        self.nameTokens = Array(Set(nameTokens))
        var other = Set<String>()
        for field in otherFields {
            guard let field else { continue }
            other.formUnion(SearchText.tokens(field))
        }
        other.subtract(self.nameTokens)
        otherTokens = Array(other)
    }

    /// Ranking tier: 4 exact name, 3 name prefix, 2 all words in name, 1 matched elsewhere.
    /// Nil when some query word isn't found.
    func tier(for plan: SearchPlan) -> Int? {
        var best: Int?
        for variant in plan.variants {
            guard let tier = tier(for: variant) else { continue }
            if tier > (best ?? 0) { best = tier }
        }
        return best
    }

    private func tier(for variant: SearchPlan.Variant) -> Int? {
        var allInName = true
        let lastIndex = variant.words.count - 1
        for (i, word) in variant.words.enumerated() {
            let isLast = i == lastIndex
            if Self.matches(word, in: nameTokens, prefix: isLast) { continue }
            allInName = false
            if !Self.matches(word, in: otherTokens, prefix: isLast) { return nil }
        }
        if nameKey == variant.key { return 4 }
        if nameKey.hasPrefix(variant.key) { return 3 }
        return allInName ? 2 : 1
    }

    private static func matches(_ word: String, in tokens: [String], prefix: Bool) -> Bool {
        if prefix {
            return tokens.contains { $0.hasPrefix(word) }
        }
        // Whole words; tolerate a plural "s" either way ("bag" ↔ "bags").
        return tokens.contains { token in
            token == word
                || (token.count == word.count + 1 && token.hasSuffix("s") && token.hasPrefix(word))
                || (word.count == token.count + 1 && word.hasSuffix("s") && word.hasPrefix(token))
        }
    }
}

extension SupportStatus {
    /// 0 verified supported, 1 unknown / pending, 2 verified not supported.
    var rankGroup: Int {
        switch self {
        case .supported: 0
        case .unknown, .checking, .needsDownload: 1
        case .unsupported, .noReleases: 2
        }
    }

    /// Hidden by the "Forever only" toggle.
    var isVerifiedUnsupported: Bool {
        switch self {
        case .unsupported, .noReleases: true
        default: false
        }
    }
}

// MARK: - Index

/// In-memory catalogue index (DESIGN.md §7.2). Immutable and `Sendable`; build once
/// per catalogue download. Queries over ~2.4k rows take well under a millisecond or two.
public struct SearchIndex: Sendable {
    public let entries: [CatalogueEntry]
    private let documents: [SearchDocument]
    private let positions: [String: Int]

    public init(entries: [CatalogueEntry]) {
        self.entries = entries
        var positions: [String: Int] = [:]
        for (i, entry) in entries.enumerated() where positions[entry.fullName.lowercased()] == nil {
            positions[entry.fullName.lowercased()] = i
        }
        self.positions = positions
        self.documents = entries.map { entry in
            let parts = entry.fullName.split(separator: "/", maxSplits: 1)
            return SearchDocument(
                name: entry.name,
                otherFields: [parts.first.map(String.init), parts.dropFirst().first.map(String.init), entry.description]
            )
        }
    }

    public var count: Int { entries.count }

    /// Matching entries, best first.
    /// - Parameter supportLookup: cached Forever status per ref, used as the tie-break within a tier.
    public func search(
        _ text: String,
        limit: Int? = nil,
        supportLookup: (AddonRef) -> SupportStatus? = { _ in nil }
    ) -> [CatalogueEntry] {
        guard let plan = SearchPlan(text) else { return [] }
        var hits: [(index: Int, tier: Int, support: Int)] = []
        for (i, document) in documents.enumerated() {
            guard let tier = document.tier(for: plan) else { continue }
            hits.append((i, tier, supportLookup(entries[i].ref)?.rankGroup ?? 1))
        }
        hits.sort { a, b in
            if a.tier != b.tier { return a.tier > b.tier }
            if a.support != b.support { return a.support < b.support }
            let da = entries[a.index].lastUpdated ?? .distantPast
            let db = entries[b.index].lastUpdated ?? .distantPast
            if da != db { return da > db }
            return entries[a.index].fullName.lowercased() < entries[b.index].fullName.lowercased()
        }
        let ordered = hits.map { entries[$0.index] }
        if let limit { return Array(ordered.prefix(limit)) }
        return ordered
    }

    /// Entries with the newest `lastUpdated`.
    public func recentlyUpdated(limit: Int) -> [CatalogueEntry] {
        Array(entries.filter { $0.lastUpdated != nil }
            .sorted { $0.lastUpdated! > $1.lastUpdated! }
            .prefix(limit))
    }

    public func entry(for ref: AddonRef) -> CatalogueEntry? {
        guard ref.source == .github, let i = positions[ref.identifier.lowercased()] else { return nil }
        return entries[i]
    }
}

extension CatalogueEntry {
    var owner: String { String(fullName.split(separator: "/").first ?? "") }
}

import Foundation

/// `[[` link completion, as in Obsidian: while the caret sits in an open `[[…`,
/// suggest notes for what's typed so far, and turn the pick into a link.
public enum LinkCompletion {
    /// An open link being typed: the query's range (just after `[[`) and text.
    /// `replace` also covers the rest of an existing link's target up to its
    /// `]]`, so picking a note while editing a link retargets it.
    public struct Context: Equatable {
        public let query: String
        public let queryRange: NSRange
        public let replace: NSRange
        /// Whether `]]` already closes the link after `replace`.
        public let closed: Bool
    }

    /// A note to suggest: its vault-relative path without `.md`, its name, and
    /// the text the link gets — the bare name, or the path when another note
    /// shares that name (a bare name would open whichever comes first).
    public struct Suggestion: Equatable {
        public let path: String
        public var name: String { (path as NSString).lastPathComponent }
        /// The folder it's in ("" at the vault root).
        public var folder: String { (path as NSString).deletingLastPathComponent }
        public let linkText: String
    }

    /// The link being typed at `caret`, if any: a `[[` earlier on the same line
    /// with only link-target text between it and the caret. An alias (`|`) or a
    /// heading (`#`) already typed ends the suggestions.
    public static func context(in text: NSString, caret: Int) -> Context? {
        guard caret >= 2, caret <= text.length else { return nil }
        var i = caret
        while i > 0 {
            let c = text.character(at: i - 1)
            if c == 0x0A || c == 0x0D || c == 0x5D /* ] */ || c == 0x7C /* | */ || c == 0x23 /* # */ { return nil }
            if c == 0x5B /* [ */ {
                guard i >= 2, text.character(at: i - 2) == 0x5B else { return nil }
                break
            }
            i -= 1
            if caret - i > 200 { return nil }
        }
        guard i > 0 else { return nil }
        let start = i
        let queryRange = NSRange(location: start, length: caret - start)
        // The rest of an existing target, up to its `]]` on this line.
        var end = caret
        while end < text.length {
            let c = text.character(at: end)
            if c == 0x0A || c == 0x0D || c == 0x5B || c == 0x7C || c == 0x23 { break }
            if c == 0x5D { break }
            end += 1
        }
        let closed = end + 1 < text.length && text.character(at: end) == 0x5D && text.character(at: end + 1) == 0x5D
        return Context(query: text.substring(with: queryRange),
                       queryRange: queryRange,
                       replace: NSRange(location: start, length: (closed ? end : caret) - start),
                       closed: closed)
    }

    /// Notes for `query`, best first. `notes` are vault-relative paths without
    /// `.md`. A match in the name beats one only through the folders; ties go to
    /// the shorter path. An empty query lists notes by name.
    public static func suggestions(for query: String, notes: [String], limit: Int = 10) -> [Suggestion] {
        let q = normalize(query.trimmingCharacters(in: .whitespaces))
        var nameCount: [String: Int] = [:]
        for path in notes { nameCount[normalize((path as NSString).lastPathComponent), default: 0] += 1 }
        let ranked: [(String, Int)]
        if q.isEmpty {
            ranked = notes.map { path -> (String, String) in (path, normalize((path as NSString).lastPathComponent)) }
                .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : ($0.0.count, $0.0) < ($1.0.count, $1.0) }
                .map { ($0.0, 0) }
        } else {
            ranked = notes.compactMap { path -> (String, Int)? in
                let name = normalize((path as NSString).lastPathComponent)
                if let s = FuzzyFilter.score(q, name) { return (path, s) }
                return FuzzyFilter.score(q, normalize(path)).map { (path, 1000 + $0) }
            }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : ($0.0.count, $0.0) < ($1.0.count, $1.0) }
        }
        return ranked.prefix(limit).map { path, _ in
            let name = (path as NSString).lastPathComponent
            return Suggestion(path: path, linkText: nameCount[normalize(name), default: 0] > 1 ? path : name)
        }
    }

    /// The edit that turns the link being typed into a link to `suggestion`:
    /// the range to replace, what goes there, and where the caret lands (after
    /// the closing `]]`).
    public static func accept(_ suggestion: Suggestion, in context: Context) -> (range: NSRange, text: String, caret: Int) {
        let text = suggestion.linkText + (context.closed ? "" : "]]")
        let caret = context.replace.location + (suggestion.linkText as NSString).length + 2
        return (context.replace, text, caret)
    }

    /// Case- and normalization-blind form for matching (a Hangul name read from
    /// disk may be decomposed while the typed query is composed).
    private static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }
}

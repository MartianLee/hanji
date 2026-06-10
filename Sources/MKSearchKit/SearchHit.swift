import Foundation

/// One global-search result. Snippet is a window around the first body match;
/// `matchRanges` are UTF-16 ranges INSIDE the snippet (for highlighting);
/// `firstMatchOffset` is the UTF-16 offset in the full body (caret jump).
public struct SearchHit: Identifiable {
    public let path: String
    public let title: String
    public let snippet: String
    public let matchRanges: [Range<Int>]
    public let firstMatchOffset: Int?
    public let score: Double
    public var id: String { path }

    /// Build a hit from a stored row + the query.
    static func make(path: String, title: String, body: String, query: String, score: Double) -> SearchHit {
        let ns = body as NSString
        let match = ns.range(of: query, options: [.caseInsensitive])
        guard match.location != NSNotFound else {
            // Title-only match: snippet is the body head. Snap the cut to a
            // composed-character boundary so a surrogate pair (e.g. 💯) at the
            // edge is never split into a malformed string.
            let headRange = ns.length == 0 ? NSRange(location: 0, length: 0)
                : ns.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: min(80, ns.length)))
            let head = ns.substring(with: headRange)
            return SearchHit(path: path, title: title, snippet: head,
                             matchRanges: [], firstMatchOffset: nil, score: score)
        }
        let start = max(0, match.location - 40)
        let end = min(ns.length, match.location + match.length + 40)
        // Snap the ±40 UTF-16 window to composed-character boundaries (emoji etc.
        // are surrogate pairs — cutting between the halves corrupts the string).
        let window = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        var snippet = ns.substring(with: window)
        snippet = snippet.replacingOccurrences(of: "\n", with: " ")
        if window.location > 0 { snippet = "…" + snippet }
        if NSMaxRange(window) < ns.length { snippet += "…" }

        // Highlight every occurrence inside the snippet (cap 5).
        let sns = snippet as NSString
        var ranges: [Range<Int>] = []
        var cursor = 0
        while ranges.count < 5 {
            let r = sns.range(of: query, options: [.caseInsensitive],
                              range: NSRange(location: cursor, length: sns.length - cursor))
            guard r.location != NSNotFound else { break }
            ranges.append(r.location..<(r.location + r.length))
            cursor = r.location + r.length
        }
        return SearchHit(path: path, title: title, snippet: snippet,
                         matchRanges: ranges, firstMatchOffset: match.location, score: score)
    }
}

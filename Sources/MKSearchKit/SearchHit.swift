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
            let headRange = ns.length == 0 ? NSRange(location: 0, length: 0)
                : ns.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: min(80, ns.length)))
            return SearchHit(path: path, title: title, snippet: ns.substring(with: headRange),
                             matchRanges: [], firstMatchOffset: nil, score: score)
        }
        let (snippet, ranges) = SnippetWindow.make(body: body, around: match, highlight: query)
        return SearchHit(path: path, title: title, snippet: snippet,
                         matchRanges: ranges, firstMatchOffset: match.location, score: score)
    }
}

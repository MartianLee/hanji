import Foundation

/// Builds a context snippet around a position in a body: ±40 UTF-16 units,
/// snapped to composed-character boundaries (surrogate-pair safe), newlines
/// flattened, ellipses added, with highlight ranges for a needle (cap 5).
enum SnippetWindow {
    static func make(body: String, around center: NSRange, highlight needle: String)
        -> (text: String, ranges: [Range<Int>]) {
        let ns = body as NSString
        let start = max(0, center.location - 40)
        let end = min(ns.length, NSMaxRange(center) + 40)
        guard end > start else { return ("", []) }
        let window = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        var snippet = ns.substring(with: window).replacingOccurrences(of: "\n", with: " ")
        if window.location > 0 { snippet = "…" + snippet }
        if NSMaxRange(window) < ns.length { snippet += "…" }

        let sns = snippet as NSString
        var ranges: [Range<Int>] = []
        var cursor = 0
        while ranges.count < 5, !needle.isEmpty {
            let r = sns.range(of: needle, options: [.caseInsensitive],
                              range: NSRange(location: cursor, length: sns.length - cursor))
            guard r.location != NSNotFound else { break }
            ranges.append(r.location..<NSMaxRange(r))
            cursor = NSMaxRange(r)
        }
        return (snippet, ranges)
    }
}

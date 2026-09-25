import Foundation

/// A non-embed link found in a note body. `target` is the raw link target
/// (before `|` alias / `#` heading); `range` is the whole token in UTF-16.
public struct LinkRef: Equatable {
    public let target: String
    public let range: Range<Int>
    public init(target: String, range: Range<Int>) {
        self.target = target
        self.range = range
    }
}

/// Extracts wikilinks (`[[Target]]`, `[[Target|alias]]`, `[[Target#heading]]`)
/// and markdown links to `.md` files. Skips embeds/images (`![[…]]`, `![…](…)`),
/// external URLs, and anything inside fenced code blocks.
public enum LinkParser {
    private static let wiki = try! NSRegularExpression(pattern: #"(?<!\!)\[\[([^\[\]]+)\]\]"#)

    public static func links(in text: String) -> [LinkRef] {
        let ns = text as NSString
        let fenced = fencedRanges(ns)
        // `fenced` is sorted and disjoint: binary-search the first fence that ends
        // after `r` starts (testing every fence per link was fences × links).
        func inFence(_ r: NSRange) -> Bool {
            var lo = 0, hi = fenced.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if NSMaxRange(fenced[mid]) <= r.location { lo = mid + 1 } else { hi = mid }
            }
            return lo < fenced.count && NSIntersectionRange(fenced[lo], r).length > 0
        }
        var out: [LinkRef] = []

        let full = NSRange(location: 0, length: ns.length)
        for m in wiki.matches(in: text, range: full) where !inFence(m.range) {
            var target = ns.substring(with: m.range(at: 1))
            if let bar = target.firstIndex(of: "|") { target = String(target[..<bar]) }
            if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
            target = target.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            out.append(LinkRef(target: target, range: m.range.location..<NSMaxRange(m.range)))
        }
        for m in markdownLinks(ns) where !inFence(m.whole) {
            var dest = ns.substring(with: m.dest)
            guard !dest.contains("://"), !dest.hasPrefix("#"), !dest.hasPrefix("mailto:") else { continue }
            if let hash = dest.firstIndex(of: "#") { dest = String(dest[..<hash]) }
            dest = dest.removingPercentEncoding ?? dest
            if dest.hasPrefix("./") { dest = String(dest.dropFirst(2)) }
            guard dest.lowercased().hasSuffix(".md") else { continue }
            out.append(LinkRef(target: dest, range: m.whole.location..<NSMaxRange(m.whole)))
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static let bang = UInt16(UnicodeScalar("!").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let closeBracket = UInt16(UnicodeScalar("]").value)
    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)

    /// `[text](dest)` matches, as the regex `(?<!!)\[[^\]]*\]\(([^)\s]+)\)` would
    /// find them: the text runs to the first `]` (and may hold `[`), the dest is
    /// non-empty and stops at `)` or whitespace. Hand-rolled because the regex
    /// retried every `[` and rescanned to the same `]` — or to the end of the note
    /// when there is none: 20k `[[` on one line took seconds on each click.
    private static func markdownLinks(_ ns: NSString) -> [(whole: NSRange, dest: NSRange)] {
        var out: [(whole: NSRange, dest: NSRange)] = []
        var closes = ForwardScan(ns) { ns, j in ns.character(at: j) == closeBracket }
        // `\s` in ICU is `\p{White_Space}`, which has no surrogates, so a lone
        // UTF-16 unit that isn't a scalar is never whitespace.
        var destEnds = ForwardScan(ns) { ns, j in
            let c = ns.character(at: j)
            return c == closeParen || (Unicode.Scalar(c)?.properties.isWhitespace ?? false)
        }
        let n = ns.length
        var i = 0
        while i < n {
            guard ns.character(at: i) == openBracket, i == 0 || ns.character(at: i - 1) != bang else { i += 1; continue }
            let close = closes.next(from: i + 1)
            guard close < n else { break }   // no `]` left for this `[` or any later one
            if close + 1 < n, ns.character(at: close + 1) == openParen {
                let end = destEnds.next(from: close + 2)
                if end < n, end > close + 2, ns.character(at: end) == closeParen {
                    out.append((whole: NSRange(location: i, length: end + 1 - i),
                                dest: NSRange(location: close + 2, length: end - close - 2)))
                    i = end + 1
                    continue
                }
            }
            i += 1
        }
        return out
    }

    /// UTF-16 ranges of fenced code blocks (``` … ```), line-based.
    private static func fencedRanges(_ ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var fenceStart: Int? = nil
        var pos = 0
        while pos < ns.length {
            let line = ns.lineRange(for: NSRange(location: pos, length: 0))
            var content = ns.substring(with: line)
            if content.hasSuffix("\n") { content.removeLast() }
            if content.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let start = fenceStart {
                    ranges.append(NSRange(location: start, length: NSMaxRange(line) - start))
                    fenceStart = nil
                } else {
                    fenceStart = line.location
                }
            }
            pos = NSMaxRange(line)
            if line.length == 0 { break }
        }
        if let start = fenceStart {   // unterminated fence runs to EOF
            ranges.append(NSRange(location: start, length: ns.length - start))
        }
        return ranges
    }
}

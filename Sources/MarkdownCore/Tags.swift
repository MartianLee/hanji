import Foundation

public enum Tags {
    /// One `#tag` in a note: its name (no `#`) and UTF-16 range (with the `#`).
    public struct Occurrence: Equatable {
        public let name: String
        public let range: Range<Int>
    }

    /// Every `#tag` in `text`, in order — the one tag grammar the index and the
    /// editor share. Obsidian's rules:
    /// - the `#` starts the line or follows whitespace (so `a#b`, `x.com/#frag`
    ///   and `[[note#part]]` aren't tags);
    /// - then letters (any script: `#일기`), digits, `_`, `-`, and `/` for nested
    ///   tags (`#project/hanji`); combining marks stay part of the tag;
    /// - at least one character isn't a digit (`#123` isn't a tag, `#2026년` is);
    /// - `# Heading` and `##` aren't tags (nothing tag-like right after the `#`);
    /// - nothing inside fenced code blocks or inline code spans.
    public static func occurrences(in text: String) -> [Occurrence] {
        let ns = text as NSString
        let code = codeRanges(ns, text)
        var nextCode = 0

        var scalars: [Unicode.Scalar] = []
        var offsets: [Int] = []           // UTF-16 offset of each scalar
        var offset = 0
        for s in text.unicodeScalars {
            scalars.append(s); offsets.append(offset); offset += s.utf16.count
        }
        func isTagScalar(_ s: Unicode.Scalar) -> Bool {
            let p = s.properties
            if p.isAlphabetic || p.numericType != nil || s == "_" || s == "-" || s == "/" { return true }
            switch p.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return true
            default: return false
            }
        }

        var out: [Occurrence] = []
        var k = 0
        while k < scalars.count {
            guard scalars[k] == "#", k == 0 || scalars[k - 1].properties.isWhitespace,
                  k + 1 < scalars.count, isTagScalar(scalars[k + 1]) else { k += 1; continue }
            var j = k + 1
            while j < scalars.count, isTagScalar(scalars[j]) { j += 1 }
            let start = offsets[k]
            let end = j < scalars.count ? offsets[j] : offset
            // Skip code: advance past code ranges that end before this tag.
            while nextCode < code.count, code[nextCode].upperBound <= start { nextCode += 1 }
            let inCode = nextCode < code.count && code[nextCode].contains(start)
            let name = String(String.UnicodeScalarView(scalars[(k + 1)..<j]))
            if !inCode, name.contains(where: { !$0.isNumber }) {
                out.append(Occurrence(name: name, range: start..<end))
            }
            k = j
        }
        return out
    }

    /// Tag names in `text`, deduplicated, in order of first appearance.
    public static func extract(from text: String) -> [String] {
        var seen: Set<String> = []   // `tags.contains` per tag was quadratic in distinct tags
        return occurrences(in: text).map(\.name).filter { seen.insert($0).inserted }
    }

    /// Fenced code blocks and inline code spans, as sorted UTF-16 ranges.
    private static func codeRanges(_ ns: NSString, _ text: String) -> [Range<Int>] {
        let fences = CodeBlockParser.regions(in: text).map(\.full)
        let backtick = UInt16(UnicodeScalar("`").value), newline = UInt16(UnicodeScalar("\n").value)
        var inline: [Range<Int>] = []
        var fence = 0
        var i = 0
        while i < ns.length {
            while fence < fences.count, fences[fence].upperBound <= i { fence += 1 }
            if fence < fences.count, fences[fence].contains(i) { i = fences[fence].upperBound; continue }
            guard ns.character(at: i) == backtick else { i += 1; continue }
            // A run of n backticks opens a span that the next run of exactly n
            // backticks on the same line closes.
            var run = i
            while run < ns.length, ns.character(at: run) == backtick { run += 1 }
            let n = run - i
            var j = run
            var closed: Int?
            while j < ns.length, ns.character(at: j) != newline {
                if ns.character(at: j) == backtick {
                    var r = j
                    while r < ns.length, ns.character(at: r) == backtick { r += 1 }
                    if r - j == n { closed = r; break }
                    j = r
                } else {
                    j += 1
                }
            }
            if let closed { inline.append(i..<closed); i = closed } else { i = run }
        }
        return (fences + inline).sorted { $0.lowerBound < $1.lowerBound }
    }
}

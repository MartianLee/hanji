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
    /// - nothing inside fenced code blocks, inline code spans or frontmatter.
    public static func occurrences(in text: String) -> [Occurrence] {
        // Code holds no tags, and neither does YAML frontmatter (`color: #ffaa00`);
        // its `tags:` key is a property, not inline tags.
        let code = ([Frontmatter.range(in: text)].compactMap { $0 } + CodeBlockParser.allCodeRanges(in: text))
            .sorted { $0.lowerBound < $1.lowerBound }
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
}

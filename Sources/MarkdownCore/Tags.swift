import Foundation

public enum Tags {
    /// Extracts `#tag` tokens (letters/digits/_/-/ allowed in the tag, `/` for
    /// nested tags). A `#` must be at a word boundary and not followed by a space
    /// (so ATX headings like `# Title` are not tags). Deduplicated, in order.
    public static func extract(from text: String) -> [String] {
        var tags: [String] = []
        var seen: Set<String> = []   // `tags.contains` per tag was quadratic in distinct tags
        let chars = Array(text)
        func isBoundary(_ i: Int) -> Bool { i <= 0 || chars[i - 1] == " " || chars[i - 1] == "\n" || chars[i - 1] == "\t" }
        func isTagChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" || c == "/" }
        var i = 0
        while i < chars.count {
            if chars[i] == "#", isBoundary(i), i + 1 < chars.count, isTagChar(chars[i + 1]) {
                var j = i + 1
                var tag = ""
                while j < chars.count, isTagChar(chars[j]) { tag.append(chars[j]); j += 1 }
                if seen.insert(tag).inserted { tags.append(tag) }
                i = j
            } else {
                i += 1
            }
        }
        return tags
    }
}

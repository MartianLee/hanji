import Foundation

/// Where a note's name appears in another note's text without a link — the
/// backlinks panel's "Unlinked mentions".
public enum Mentions {
    private static let wiki = try! NSRegularExpression(pattern: #"!?\[\[[^\[\]]+\]\]"#)

    /// Ranges of `name` in `text`, ignoring case, outside code, frontmatter and
    /// links. No letter or digit may come before it, and no ASCII letter or digit
    /// after — "Plan" isn't in "Planning", but "한지" is in "한지는".
    public static func unlinked(of name: String, in text: String) -> [Range<Int>] {
        let ns = text as NSString
        let needle = name.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var excluded = CodeBlockParser.allCodeRanges(in: text)
        if let front = Frontmatter.range(in: text) { excluded.append(front) }
        excluded += wiki.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range.location..<NSMaxRange($0.range) }
        excluded += LinkParser.markdownLinks(ns).map { $0.whole.location..<NSMaxRange($0.whole) }
        var out: [Range<Int>] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: needle, options: .caseInsensitive, range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound, r.length > 0 else { break }
            from = NSMaxRange(r)
            let range = r.location..<NSMaxRange(r)
            guard !excluded.contains(where: { $0.overlaps(range) }) else { continue }
            if r.location > 0 {
                let prev = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: r.location - 1))
                if prev.first.map({ $0.isLetter || $0.isNumber || $0 == "_" }) == true { continue }
            }
            if NSMaxRange(r) < ns.length {
                let next = ns.character(at: NSMaxRange(r))
                if next < 0x80, let scalar = Unicode.Scalar(next),
                   scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar)) || next == 0x5F { continue }
            }
            out.append(range)
        }
        return out
    }
}

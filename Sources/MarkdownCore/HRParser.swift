import Foundation

/// Finds horizontal-rule lines (`---`, `***`, `___`, 3+ repeats, up to 3 leading
/// spaces) so the editor can render them as drawn dividers. Skips a leading
/// frontmatter block (only when it has a closing delimiter) and fenced code.
public enum HRParser {
    /// UTF-16 line ranges (excluding the newline) of every horizontal rule.
    public static func lines(in text: String) -> [Range<Int>] {
        let ns = text as NSString
        var out: [Range<Int>] = []
        var openFence: Fence?
        var inList = false
        var pos = 0
        var lineIndex = 0
        var skipUntilFrontmatterClose = false

        // Runs on every keystroke's widget pass, so a line is only turned into a
        // String when its first character could make it matter — a fence, a
        // rule, a frontmatter `---`; list context is read off the UTF-16 as is.
        while pos < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: pos, length: 0))
            var contentEnd = lineRange.location + lineRange.length
            while contentEnd > lineRange.location, isNewline(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
            var first = lineRange.location            // first char past spaces and tabs
            while first < contentEnd, ns.character(at: first) == 0x20 || ns.character(at: first) == 0x09 { first += 1 }
            let lead: UInt16 = first < contentEnd ? ns.character(at: first) : 0
            lazy var content = ns.substring(with: NSRange(location: lineRange.location, length: contentEnd - lineRange.location))

            // (`---` checks trim Unicode blanks too, so a non-ASCII lead is checked properly.)
            if lineIndex == 0, lead == 0x2D || lead >= 0x80, content.trimmingCharacters(in: .whitespaces) == "---",
               hasFrontmatterClose(ns, after: lineRange) {
                skipUntilFrontmatterClose = true
            } else if skipUntilFrontmatterClose {
                if lead == 0x2D || lead >= 0x80, content.trimmingCharacters(in: .whitespaces) == "---" { skipUntilFrontmatterClose = false }
            } else if let open = openFence {
                if lead == 0x60 || lead == 0x7E, open.isClosed(by: content) {
                    openFence = nil
                    inList = ListContext.after(ns, from: lineRange.location, to: contentEnd, inList: inList)
                }
            } else {
                if lead == 0x60 || lead == 0x7E, let fence = Fence.opening(content, inList: inList) {
                    openFence = fence
                } else if lead == 0x2D || lead == 0x2A || lead == 0x5F, isRule(content) {
                    out.append(lineRange.location..<contentEnd)
                }
                inList = ListContext.after(ns, from: lineRange.location, to: contentEnd, inList: inList)
            }

            pos = lineRange.location + lineRange.length
            lineIndex += 1
            if lineRange.length == 0 { break }
        }
        return out
    }

    /// What `Character.isNewline` strips from a line's end.
    private static func isNewline(_ c: UInt16) -> Bool {
        (0x0A...0x0D).contains(c) || c == 0x85 || c == 0x2028 || c == 0x2029
    }

    private static func isRule(_ line: String) -> Bool {
        var s = Substring(line)
        var leading = 0
        while s.first == " " { s.removeFirst(); leading += 1 }
        guard leading <= 3 else { return false }
        while s.last == " " { s.removeLast() }
        guard let mark = s.first, "-*_".contains(mark), s.count >= 3 else { return false }
        return s.allSatisfy { $0 == mark }
    }

    private static func hasFrontmatterClose(_ ns: NSString, after openLine: NSRange) -> Bool {
        var pos = openLine.location + openLine.length
        while pos < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: pos, length: 0))
            var content = ns.substring(with: lineRange)
            while content.last?.isNewline == true { content.removeLast() }   // "\r\n" is one Character
            if content.trimmingCharacters(in: .whitespaces) == "---" { return true }
            pos = lineRange.location + lineRange.length
            if lineRange.length == 0 { break }
        }
        return false
    }
}

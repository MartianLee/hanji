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
        var pos = 0
        var lineIndex = 0
        var skipUntilFrontmatterClose = false

        while pos < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: pos, length: 0))
            var content = ns.substring(with: lineRange)
            while content.last?.isNewline == true { content.removeLast() }   // "\r\n" is one Character
            let trimmed = content.trimmingCharacters(in: .whitespaces)

            if lineIndex == 0, trimmed == "---", hasFrontmatterClose(ns, after: lineRange) {
                skipUntilFrontmatterClose = true
            } else if skipUntilFrontmatterClose {
                if trimmed == "---" { skipUntilFrontmatterClose = false }
            } else if let open = openFence {
                if open.isClosed(by: content) { openFence = nil }
            } else if let fence = Fence.opening(content) {
                openFence = fence
            } else if isRule(content) {
                out.append(lineRange.location..<(lineRange.location + (content as NSString).length))
            }

            pos = lineRange.location + lineRange.length
            lineIndex += 1
            if lineRange.length == 0 { break }
        }
        return out
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

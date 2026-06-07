import Foundation

public enum InlineTokenizer {
    /// Parse a document into spans. Line-based: headings consume a whole line;
    /// otherwise bold/italic/inline-code are scanned within each line.
    public static func spans(in text: String) -> [MarkSpan] {
        var result: [MarkSpan] = []
        let ns = text as NSString
        let length = ns.length
        let newline = UInt16(UnicodeScalar("\n").value)

        var lineStart = 0
        while lineStart <= length {
            var lineEnd = lineStart
            while lineEnd < length && ns.character(at: lineEnd) != newline { lineEnd += 1 }
            let lineRange = lineStart..<lineEnd
            let lineText = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            parseLine(lineText as NSString, lineStart: lineStart, lineRange: lineRange, into: &result)
            if lineEnd == length { break }
            lineStart = lineEnd + 1
        }
        return result
    }

    private static let hash = UInt16(UnicodeScalar("#").value)
    private static let space = UInt16(UnicodeScalar(" ").value)
    private static let star = UInt16(UnicodeScalar("*").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)

    private static func parseLine(_ ns: NSString, lineStart: Int, lineRange: Range<Int>,
                                  into result: inout [MarkSpan]) {
        if let heading = headingSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(heading)
            return
        }
        let n = ns.length
        var i = 0
        while i < n {
            let c = ns.character(at: i)
            if c == backtick, let (span, next) = codeSpan(ns, from: i, lineStart: lineStart, lineRange: lineRange) {
                result.append(span); i = next; continue
            }
            if c == star {
                if i + 1 < n && ns.character(at: i + 1) == star {
                    if let (span, next) = pairSpan(ns, marker: "**", style: .bold, from: i, lineStart: lineStart, lineRange: lineRange) {
                        result.append(span); i = next; continue
                    }
                } else if let (span, next) = pairSpan(ns, marker: "*", style: .italic, from: i, lineStart: lineStart, lineRange: lineRange) {
                    result.append(span); i = next; continue
                }
            }
            i += 1
        }
    }

    private static func headingSpan(_ ns: NSString, lineStart: Int, lineRange: Range<Int>) -> MarkSpan? {
        let n = ns.length
        var hashes = 0
        while hashes < n && ns.character(at: hashes) == hash { hashes += 1 }
        guard hashes >= 1, hashes <= 6, hashes < n, ns.character(at: hashes) == space else { return nil }
        let markerEnd = hashes + 1 // include the space
        let markers = [(lineStart)..<(lineStart + markerEnd)]
        let content = (lineStart + markerEnd)..<(lineStart + n)
        return MarkSpan(style: .heading(hashes), content: content, markers: markers, line: lineRange)
    }

    private static func codeSpan(_ ns: NSString, from start: Int, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let n = ns.length
        var j = start + 1
        while j < n && ns.character(at: j) != backtick { j += 1 }
        guard j < n, j > start + 1 else { return nil }
        let span = MarkSpan(
            style: .inlineCode,
            content: (lineStart + start + 1)..<(lineStart + j),
            markers: [(lineStart + start)..<(lineStart + start + 1), (lineStart + j)..<(lineStart + j + 1)],
            line: lineRange)
        return (span, j + 1)
    }

    private static func pairSpan(_ ns: NSString, marker: String, style: SpanStyle,
                                 from start: Int, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let m = marker as NSString
        let mlen = m.length
        let n = ns.length
        let contentStart = start + mlen
        var j = contentStart
        while j <= n - mlen {
            if matches(ns, at: j, marker: m) {
                if marker == "*" && j + 1 < n && ns.character(at: j + 1) == star {
                    j += 1; continue   // a '**' is not an italic close
                }
                guard j > contentStart else { return nil }
                let span = MarkSpan(
                    style: style,
                    content: (lineStart + contentStart)..<(lineStart + j),
                    markers: [(lineStart + start)..<(lineStart + start + mlen),
                              (lineStart + j)..<(lineStart + j + mlen)],
                    line: lineRange)
                return (span, j + mlen)
            }
            j += 1
        }
        return nil
    }

    private static func matches(_ ns: NSString, at i: Int, marker: NSString) -> Bool {
        guard i + marker.length <= ns.length else { return false }
        for k in 0..<marker.length where ns.character(at: i + k) != marker.character(at: k) { return false }
        return true
    }
}

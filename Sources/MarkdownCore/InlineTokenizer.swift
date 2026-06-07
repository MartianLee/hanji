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
        var lineIndex = 0
        var inFrontmatter = false
        var inCodeBlock = false
        var inCallout = false
        while lineStart <= length {
            var lineEnd = lineStart
            while lineEnd < length && ns.character(at: lineEnd) != newline { lineEnd += 1 }
            let lineRange = lineStart..<lineEnd
            let lineText = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))

            if lineIndex == 0 && lineText == "---" {
                inFrontmatter = true
                result.append(MarkSpan(style: .frontmatter, content: lineRange, markers: [], line: lineRange))
            } else if inFrontmatter {
                result.append(MarkSpan(style: .frontmatter, content: lineRange, markers: [], line: lineRange))
                if lineText == "---" { inFrontmatter = false }
            } else if inCodeBlock {
                result.append(MarkSpan(style: .codeBlock, content: lineRange, markers: [], line: lineRange))
                if lineText.hasPrefix("```") { inCodeBlock = false }
            } else if lineText.hasPrefix("```") {
                inCodeBlock = true
                inCallout = false
                result.append(MarkSpan(style: .codeBlock, content: lineRange, markers: [], line: lineRange))
            } else if lineText.hasPrefix("> ") && (inCallout || String(lineText.dropFirst(2)).hasPrefix("[!")) {
                inCallout = true
                let markers = [lineStart..<(lineStart + 2)]
                let content = (lineStart + 2)..<(lineStart + (lineText as NSString).length)
                result.append(MarkSpan(style: .callout, content: content, markers: markers, line: lineRange))
            } else {
                inCallout = false
                parseLine(lineText as NSString, lineStart: lineStart, lineRange: lineRange, into: &result)
            }

            if lineEnd == length { break }
            lineStart = lineEnd + 1
            lineIndex += 1
        }
        return result
    }

    private static let hash = UInt16(UnicodeScalar("#").value)
    private static let space = UInt16(UnicodeScalar(" ").value)
    private static let star = UInt16(UnicodeScalar("*").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let closeBracket = UInt16(UnicodeScalar("]").value)
    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)
    private static let pipeChar = UInt16(UnicodeScalar("|").value)
    private static let gt = UInt16(UnicodeScalar(">").value)
    private static let dash = UInt16(UnicodeScalar("-").value)
    private static let plus = UInt16(UnicodeScalar("+").value)
    private static let xLower = UInt16(UnicodeScalar("x").value)
    private static let xUpper = UInt16(UnicodeScalar("X").value)

    private static func parseLine(_ ns: NSString, lineStart: Int, lineRange: Range<Int>,
                                  into result: inout [MarkSpan]) {
        if let heading = headingSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(heading)
            return
        }
        if let quote = blockquoteSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(quote)
            return
        }
        if let task = taskSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(task)
            return
        }
        if let list = listSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(list)
            return
        }
        let n = ns.length
        var i = 0
        while i < n {
            let c = ns.character(at: i)
            if c == backtick, let (span, next) = codeSpan(ns, from: i, lineStart: lineStart, lineRange: lineRange) {
                result.append(span); i = next; continue
            }
            if c == openBracket, let (span, next) = bracketSpan(ns, from: i, lineStart: lineStart, lineRange: lineRange) {
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

    private static func blockquoteSpan(_ ns: NSString, lineStart: Int, lineRange: Range<Int>) -> MarkSpan? {
        let n = ns.length
        guard n >= 2, ns.character(at: 0) == gt, ns.character(at: 1) == space else { return nil }
        let markers = [(lineStart)..<(lineStart + 2)]   // "> "
        let content = (lineStart + 2)..<(lineStart + n)
        return MarkSpan(style: .blockquote, content: content, markers: markers, line: lineRange)
    }

    private static func taskSpan(_ ns: NSString, lineStart: Int, lineRange: Range<Int>) -> MarkSpan? {
        let n = ns.length
        guard n >= 6,
              ns.character(at: 0) == dash, ns.character(at: 1) == space,
              ns.character(at: 2) == openBracket, ns.character(at: 4) == closeBracket,
              ns.character(at: 5) == space else { return nil }
        let mark = ns.character(at: 3)
        let done: Bool
        if mark == space { done = false }
        else if mark == xLower || mark == xUpper { done = true }
        else { return nil }
        let content = (lineStart + 6)..<(lineStart + n)
        return MarkSpan(style: .task(done), content: content, markers: [], line: lineRange)
    }

    private static func listSpan(_ ns: NSString, lineStart: Int, lineRange: Range<Int>) -> MarkSpan? {
        let n = ns.length
        guard n >= 2, ns.character(at: 1) == space else { return nil }
        let c0 = ns.character(at: 0)
        guard c0 == dash || c0 == star || c0 == plus else { return nil }
        let content = (lineStart + 2)..<(lineStart + n)
        return MarkSpan(style: .listItem, content: content, markers: [], line: lineRange)
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

    private static func bracketSpan(_ ns: NSString, from start: Int, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        if start + 1 < ns.length && ns.character(at: start + 1) == openBracket {
            return wikilinkSpan(ns, from: start, lineStart: lineStart, lineRange: lineRange)
        }
        return markdownLinkSpan(ns, from: start, lineStart: lineStart, lineRange: lineRange)
    }

    private static func wikilinkSpan(_ ns: NSString, from start: Int, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let n = ns.length
        let innerStart = start + 2
        var j = innerStart
        while j + 1 < n && !(ns.character(at: j) == closeBracket && ns.character(at: j + 1) == closeBracket) { j += 1 }
        guard j + 1 < n, ns.character(at: j) == closeBracket, ns.character(at: j + 1) == closeBracket, j > innerStart else { return nil }
        let closeStart = j
        var pipe = -1
        var k = innerStart
        while k < closeStart { if ns.character(at: k) == pipeChar { pipe = k; break }; k += 1 }
        let openMarker = (lineStart + start)..<(lineStart + start + 2)
        let closeMarker = (lineStart + closeStart)..<(lineStart + closeStart + 2)
        if pipe >= 0 {
            guard pipe + 1 < closeStart else { return nil }
            let targetPipeMarker = (lineStart + innerStart)..<(lineStart + pipe + 1)
            let content = (lineStart + pipe + 1)..<(lineStart + closeStart)
            return (MarkSpan(style: .link, content: content, markers: [openMarker, targetPipeMarker, closeMarker], line: lineRange), closeStart + 2)
        }
        let content = (lineStart + innerStart)..<(lineStart + closeStart)
        return (MarkSpan(style: .link, content: content, markers: [openMarker, closeMarker], line: lineRange), closeStart + 2)
    }

    private static func markdownLinkSpan(_ ns: NSString, from start: Int, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let n = ns.length
        var j = start + 1
        while j < n && ns.character(at: j) != closeBracket { j += 1 }
        guard j < n, j > start + 1 else { return nil }
        guard j + 1 < n, ns.character(at: j + 1) == openParen else { return nil }
        var k = j + 2
        while k < n && ns.character(at: k) != closeParen { k += 1 }
        guard k < n else { return nil }
        let openMarker = (lineStart + start)..<(lineStart + start + 1)
        let tailMarker = (lineStart + j)..<(lineStart + k + 1)   // ](url)
        let content = (lineStart + start + 1)..<(lineStart + j)
        return (MarkSpan(style: .link, content: content, markers: [openMarker, tailMarker], line: lineRange), k + 1)
    }

    private static func matches(_ ns: NSString, at i: Int, marker: NSString) -> Bool {
        guard i + marker.length <= ns.length else { return false }
        for k in 0..<marker.length where ns.character(at: i + k) != marker.character(at: k) { return false }
        return true
    }
}

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
        var state = LineState()
        // Frontmatter needs its closing `---`: a lone `---` on the first line is a
        // rule, not the start of a note-long YAML block.
        let frontmatterCloses = Frontmatter.range(in: text) != nil
        while lineStart <= length {
            var lineEnd = lineStart
            while lineEnd < length && ns.character(at: lineEnd) != newline { lineEnd += 1 }
            let lineText = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            tokenizeLine(lineText, at: lineStart, opensFrontmatter: lineIndex == 0 && frontmatterCloses,
                         state: &state, into: &result)
            if lineEnd == length { break }
            lineStart = lineEnd + 1
            lineIndex += 1
        }
        // Tags come from the shared grammar (which already skips code), so the
        // editor and the index agree on what a tag is.
        let newlineUnit = newline
        for tag in Tags.occurrences(in: text) {
            var start = tag.range.lowerBound, end = tag.range.upperBound
            while start > 0 && ns.character(at: start - 1) != newlineUnit { start -= 1 }
            while end < length && ns.character(at: end) != newlineUnit { end += 1 }
            result.append(MarkSpan(style: .tag, content: tag.range, markers: [], line: start..<end))
        }
        return result
    }

    /// What one line's tokenizing carries to the next: inside frontmatter, a code
    /// fence (and which one closes it), a callout, or a list item (see
    /// `ListContext`: where a fence may sit deeper).
    public struct LineState: Hashable {
        var inFrontmatter = false
        var openFence: Fence?
        var inCallout = false
        var inList = false
        public init() {}
    }

    /// One line's spans (tags aside), the line starting at `lineStart`; advances
    /// `state` for the next line. `opensFrontmatter`: this is line 1 and the note
    /// has a closed frontmatter block.
    static func tokenizeLine(_ lineText: String, at lineStart: Int, opensFrontmatter: Bool,
                             state: inout LineState, into result: inout [MarkSpan]) {
        let lineRange = lineStart..<(lineStart + (lineText as NSString).length)
        // Structure is judged without a CRLF line's trailing `\r`.
        let bare = lineText.last == "\r" ? String(lineText.dropLast()) : lineText
        if opensFrontmatter && bare == "---" {
            state.inFrontmatter = true
            result.append(MarkSpan(style: .frontmatter, content: lineRange, markers: [], line: lineRange))
        } else if state.inFrontmatter {
            result.append(MarkSpan(style: .frontmatter, content: lineRange, markers: [], line: lineRange))
            if bare == "---" { state.inFrontmatter = false }
        } else if let open = state.openFence {
            result.append(MarkSpan(style: .codeBlock, content: lineRange, markers: [], line: lineRange))
            if open.isClosed(by: lineText) {
                state.openFence = nil
                state.inList = ListContext.after(bare, inList: state.inList)
            }
        } else if let fence = Fence.opening(lineText, inList: state.inList) {
            state.openFence = fence
            state.inCallout = false
            state.inList = ListContext.after(bare, inList: state.inList)
            result.append(MarkSpan(style: .codeBlock, content: lineRange, markers: [], line: lineRange))
        } else if lineText.hasPrefix("> ") && (state.inCallout || String(lineText.dropFirst(2)).hasPrefix("[!")) {
            state.inCallout = true
            state.inList = false
            let markers = [lineStart..<(lineStart + 2)]
            let content = (lineStart + 2)..<lineRange.upperBound
            result.append(MarkSpan(style: .callout, content: content, markers: markers, line: lineRange))
            scanInline(lineText as NSString, from: 2, lineStart: lineStart, lineRange: lineRange, into: &result)
        } else {
            state.inCallout = false
            state.inList = ListContext.after(bare, inList: state.inList)
            parseLine(lineText as NSString, lineStart: lineStart, lineRange: lineRange, into: &result)
        }
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
    private static let dot = UInt16(UnicodeScalar(".").value)
    private static let zero = UInt16(UnicodeScalar("0").value)
    private static let nine = UInt16(UnicodeScalar("9").value)
    private static let tilde = UInt16(UnicodeScalar("~").value)
    private static let equals = UInt16(UnicodeScalar("=").value)
    private static let dollar = UInt16(UnicodeScalar("$").value)
    private static let backslash = UInt16(UnicodeScalar("\\").value)
    private static let caret = UInt16(UnicodeScalar("^").value)
    private static let colon = UInt16(UnicodeScalar(":").value)
    private static let tab = UInt16(9)

    private static func parseLine(_ ns: NSString, lineStart: Int, lineRange: Range<Int>,
                                  into result: inout [MarkSpan]) {
        if let (def, contentOffset) = footnoteDefSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(def)
            scanInline(ns, from: contentOffset, lineStart: lineStart, lineRange: lineRange, into: &result)
            return
        }
        if let heading = headingSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(heading)
            // Inline styles compose with the heading font (trait-based styler).
            let markerEnd = heading.content.lowerBound - lineStart
            scanInline(ns, from: markerEnd, lineStart: lineStart, lineRange: lineRange, into: &result)
            return
        }
        if let quote = blockquoteSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(quote)
            scanInline(ns, from: 2, lineStart: lineStart, lineRange: lineRange, into: &result)
            return
        }
        if let (task, contentOffset) = taskSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(task)
            scanInline(ns, from: contentOffset, lineStart: lineStart, lineRange: lineRange, into: &result)
            return
        }
        if let (list, contentOffset) = listSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(list)
            scanInline(ns, from: contentOffset, lineStart: lineStart, lineRange: lineRange, into: &result)
            return
        }
        if let (ordered, contentOffset) = orderedSpan(ns, lineStart: lineStart, lineRange: lineRange) {
            result.append(ordered)
            scanInline(ns, from: contentOffset, lineStart: lineStart, lineRange: lineRange, into: &result)
            return
        }
        scanInline(ns, from: 0, lineStart: lineStart, lineRange: lineRange, into: &result)
    }

    /// Bold/italic/inline-code/links scanned from `from` (so list bullets,
    /// quotes, callouts, and tasks style their content like plain lines).
    private static func scanInline(_ ns: NSString, from: Int, lineStart: Int, lineRange: Range<Int>,
                                   into result: inout [MarkSpan]) {
        let n = ns.length
        var ahead = LinkScans(ns)
        var i = from
        while i < n {
            let c = ns.character(at: i)
            if c == backtick, let (span, next) = codeSpan(ns, from: i, lineStart: lineStart, lineRange: lineRange) {
                result.append(span); i = next; continue
            }
            if c == backslash, i + 1 < n, ns.character(at: i + 1) == dollar { i += 2; continue }
            if c == dollar, let (span, next) = mathSpan(ns, from: i, lineStart: lineStart, lineRange: lineRange) {
                result.append(span); i = next; continue
            }
            if c == openBracket, let (span, next) = footnoteRefSpan(ns, from: i, lineStart: lineStart, lineRange: lineRange) {
                result.append(span); i = next; continue
            }
            if c == openBracket, let (span, next) = bracketSpan(ns, from: i, ahead: &ahead, lineStart: lineStart, lineRange: lineRange) {
                result.append(span); i = next; continue
            }
            if c == tilde, i + 1 < n, ns.character(at: i + 1) == tilde,
               let (span, next) = pairSpan(ns, marker: "~~", style: .strikethrough, tight: true,
                                           from: i, lineStart: lineStart, lineRange: lineRange) {
                result.append(span); i = next; continue
            }
            if c == equals, i + 1 < n, ns.character(at: i + 1) == equals,
               let (span, next) = pairSpan(ns, marker: "==", style: .highlight, tight: true,
                                           from: i, lineStart: lineStart, lineRange: lineRange) {
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

    private static func leadingIndent(_ ns: NSString) -> Int {
        let tab = UInt16(9)
        var i = 0
        while i < ns.length, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1 }
        return i
    }

    private static func taskSpan(_ ns: NSString, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let n = ns.length
        let base = leadingIndent(ns)
        guard n >= base + 6,
              ns.character(at: base) == dash, ns.character(at: base + 1) == space,
              ns.character(at: base + 2) == openBracket, ns.character(at: base + 4) == closeBracket,
              ns.character(at: base + 5) == space else { return nil }
        let mark = ns.character(at: base + 3)
        let done: Bool
        if mark == space { done = false }
        else if mark == xLower || mark == xUpper { done = true }
        else { return nil }
        let content = (lineStart + base + 6)..<(lineStart + n)
        return (MarkSpan(style: .task(done), content: content, markers: [], line: lineRange), base + 6)
    }

    private static func listSpan(_ ns: NSString, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let n = ns.length
        let base = leadingIndent(ns)
        guard n >= base + 2, ns.character(at: base + 1) == space else { return nil }
        let c0 = ns.character(at: base)
        guard c0 == dash || c0 == star || c0 == plus else { return nil }
        let content = (lineStart + base + 2)..<(lineStart + n)
        return (MarkSpan(style: .listItem, content: content, markers: [], line: lineRange), base + 2)
    }

    /// `1. ` / `2) ` — no marker range: the number is what the reader is meant to
    /// see, so it is never hidden (unlike a bullet's `- `, which a • replaces).
    private static func orderedSpan(_ ns: NSString, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let n = ns.length
        let base = leadingIndent(ns)
        var j = base
        while j < n, ns.character(at: j) >= zero, ns.character(at: j) <= nine { j += 1 }
        guard j > base, j - base <= 9, j + 1 < n else { return nil }
        let delim = ns.character(at: j)
        guard delim == dot || delim == closeParen, ns.character(at: j + 1) == space else { return nil }
        let markerEnd = j + 2
        let content = (lineStart + markerEnd)..<(lineStart + n)
        return (MarkSpan(style: .orderedItem, content: content, markers: [], line: lineRange), markerEnd)
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

    /// `tight`: the content may neither start nor end with a blank, so
    /// `a == b == c` isn't a highlight.
    private static func pairSpan(_ ns: NSString, marker: String, style: SpanStyle, tight: Bool = false,
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
                if tight {
                    func blank(_ k: Int) -> Bool { ns.character(at: k) == space || ns.character(at: k) == tab }
                    guard !blank(contentStart), !blank(j - 1) else { return nil }
                }
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

    /// `$x$` (or `$$x$$` written on one line): the opening delimiter before a
    /// non-blank, the closing one after a non-blank and — for `$` — not before a
    /// digit, so `$5 and $10` stays text. `\$` is never a delimiter.
    private static func mathSpan(_ ns: NSString, from start: Int, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let n = ns.length
        let mlen = start + 1 < n && ns.character(at: start + 1) == dollar ? 2 : 1
        let contentStart = start + mlen
        func blank(_ k: Int) -> Bool { ns.character(at: k) == space || ns.character(at: k) == tab }
        guard contentStart < n, !blank(contentStart), ns.character(at: contentStart) != dollar else { return nil }
        var j = contentStart
        while j < n {
            let c = ns.character(at: j)
            if c == backslash { j += 2; continue }
            if c == dollar {
                guard mlen == 1 || (j + 1 < n && ns.character(at: j + 1) == dollar) else { j += 1; continue }
                guard !blank(j - 1) else { return nil }
                let after = j + mlen
                if mlen == 1, after < n, ns.character(at: after) >= zero, ns.character(at: after) <= nine { return nil }
                let span = MarkSpan(style: .math,
                                    content: (lineStart + contentStart)..<(lineStart + j),
                                    markers: [(lineStart + start)..<(lineStart + contentStart),
                                              (lineStart + j)..<(lineStart + after)],
                                    line: lineRange)
                return (span, after)
            }
            j += 1
        }
        return nil
    }

    /// The index of the `]` closing a footnote label `[^id]` that starts at
    /// `start`, or nil: an id is one or more characters, none blank or a bracket.
    private static func footnoteLabelEnd(_ ns: NSString, from start: Int) -> Int? {
        let n = ns.length
        guard start + 2 < n, ns.character(at: start) == openBracket, ns.character(at: start + 1) == caret else { return nil }
        var j = start + 2
        while j < n {
            let c = ns.character(at: j)
            if c == closeBracket { return j > start + 2 ? j : nil }
            if c == space || c == tab || c == openBracket { return nil }
            j += 1
        }
        return nil
    }

    private static func footnoteRefSpan(_ ns: NSString, from start: Int, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        guard let close = footnoteLabelEnd(ns, from: start) else { return nil }
        let span = MarkSpan(style: .footnoteRef, content: (lineStart + start + 2)..<(lineStart + close),
                            markers: [(lineStart + start)..<(lineStart + start + 2),
                                      (lineStart + close)..<(lineStart + close + 1)],
                            line: lineRange)
        return (span, close + 1)
    }

    /// `[^id]:` opening a line: the definition's label, kept visible.
    private static func footnoteDefSpan(_ ns: NSString, lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        guard let close = footnoteLabelEnd(ns, from: 0), close + 1 < ns.length,
              ns.character(at: close + 1) == colon else { return nil }
        return (MarkSpan(style: .footnoteDef, content: lineStart..<(lineStart + close + 2), markers: [], line: lineRange), close + 2)
    }

    /// Where the next `]]`, `|`, `]` and `)` are. Every `[` on the line asks,
    /// and an unclosed one used to rescan to the end of the line each time —
    /// 20k `[[` took seconds, and this runs on every keystroke.
    private struct LinkScans {
        var wikiClose, pipe, close, paren: ForwardScan
        init(_ ns: NSString) {
            wikiClose = ForwardScan(ns) { ns, j in
                j + 1 < ns.length && ns.character(at: j) == closeBracket && ns.character(at: j + 1) == closeBracket
            }
            pipe = ForwardScan(ns) { ns, j in ns.character(at: j) == pipeChar }
            close = ForwardScan(ns) { ns, j in ns.character(at: j) == closeBracket }
            paren = ForwardScan(ns) { ns, j in ns.character(at: j) == closeParen }
        }
    }

    private static func bracketSpan(_ ns: NSString, from start: Int, ahead: inout LinkScans,
                                    lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        if start + 1 < ns.length && ns.character(at: start + 1) == openBracket {
            return wikilinkSpan(ns, from: start, ahead: &ahead, lineStart: lineStart, lineRange: lineRange)
        }
        return markdownLinkSpan(ns, from: start, ahead: &ahead, lineStart: lineStart, lineRange: lineRange)
    }

    private static func wikilinkSpan(_ ns: NSString, from start: Int, ahead: inout LinkScans,
                                     lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let n = ns.length
        let innerStart = start + 2
        let j = ahead.wikiClose.next(from: innerStart)
        guard j + 1 < n, j > innerStart else { return nil }
        let closeStart = j
        let bar = ahead.pipe.next(from: innerStart)
        let pipe = bar < closeStart ? bar : -1
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

    private static func markdownLinkSpan(_ ns: NSString, from start: Int, ahead: inout LinkScans,
                                         lineStart: Int, lineRange: Range<Int>) -> (MarkSpan, Int)? {
        let n = ns.length
        let j = ahead.close.next(from: start + 1)
        guard j < n, j > start + 1 else { return nil }
        guard j + 1 < n, ns.character(at: j + 1) == openParen else { return nil }
        let k = ahead.paren.next(from: j + 2)
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

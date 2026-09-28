import Foundation
import MarkdownCore

// Frozen copies of the parsers as they were before their fast paths, the reference
// the ParserEquivalence check holds the fast versions to. Do not edit.


/// Finds horizontal-rule lines (`---`, `***`, `___`, 3+ repeats, up to 3 leading
/// spaces) so the editor can render them as drawn dividers. Skips a leading
/// frontmatter block (only when it has a closing delimiter) and fenced code.
enum LegacyHRParser {
    /// UTF-16 line ranges (excluding the newline) of every horizontal rule.
    static func lines(in text: String) -> [Range<Int>] {
        let ns = text as NSString
        var out: [Range<Int>] = []
        var openFence: Fence?
        var inList = false
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
                if open.isClosed(by: content) {
                    openFence = nil
                    inList = ListContext.after(content, inList: inList)
                }
            } else {
                if let fence = Fence.opening(content, inList: inList) {
                    openFence = fence
                } else if isRule(content) {
                    out.append(lineRange.location..<(lineRange.location + (content as NSString).length))
                }
                inList = ListContext.after(content, inList: inList)
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

enum LegacyImageParser {
    /// Own-line image references: `![[path]]` (embed) or `![alt](path)`.
    static func images(in text: String) -> [ImageRef] {
        var out: [ImageRef] = []
        let ns = text as NSString
        let nl = UInt16(UnicodeScalar("\n").value)
        var start = 0
        while start <= ns.length {
            var end = start
            while end < ns.length && ns.character(at: end) != nl { end += 1 }
            let raw = ns.substring(with: NSRange(location: start, length: end - start))
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("![["), line.hasSuffix("]]") {
                var inner = String(line.dropFirst(3).dropLast(2))
                if let bar = inner.firstIndex(of: "|") { inner = String(inner[..<bar]) }
                inner = inner.trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty { out.append(ImageRef(path: inner, line: start..<end)) }
            } else if line.hasPrefix("!["), line.hasSuffix(")"), let p = line.range(of: "](") {
                let path = String(line[p.upperBound...].dropLast())
                if !path.isEmpty { out.append(ImageRef(path: path, line: start..<end)) }
            }
            if end == ns.length { break }
            start = end + 1
        }
        return out
    }
}

/// Finds pipe tables so the editor can draw them as a grid. Whether a line is a
/// header depends on the line *below* it (the delimiter row), which the
/// line-by-line tokenizer cache can't see — hence a block pass of its own, like
/// `HRParser`. Fenced code (unclosed fences included) and frontmatter hold no tables.
enum LegacyTableParser {
    /// Every table in `text`, in document order.
    static func tables(in text: String) -> [MarkdownTable] {
        guard text.contains("|") else { return [] }
        let ns = text as NSString
        let excluded = CodeBlockParser.codeRanges(in: text) + (Frontmatter.range(in: text).map { [$0] } ?? [])
        // Lines: start offset, and text without its `\n` / `\r\n`.
        var lines: [(start: Int, text: String)] = []
        let newline = UInt16(UnicodeScalar("\n").value)
        var start = 0
        while start <= ns.length {
            var end = start
            while end < ns.length && ns.character(at: end) != newline { end += 1 }
            var line = ns.substring(with: NSRange(location: start, length: end - start))
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append((start, line))
            if end == ns.length { break }
            start = end + 1
        }
        // Lines inside code or frontmatter, in one pass: both lists are in order.
        let ordered = excluded.sorted { $0.lowerBound < $1.lowerBound }
        var inExcluded = [Bool](repeating: false, count: lines.count)
        var next = 0
        for (i, line) in lines.enumerated() {
            while next < ordered.count, ordered[next].upperBound <= line.start { next += 1 }
            inExcluded[i] = next < ordered.count && ordered[next].contains(line.start)
        }
        func usable(_ i: Int) -> Bool { i < lines.count && !inExcluded[i] }

        var out: [MarkdownTable] = []
        var i = 0
        while i + 1 < lines.count {
            guard usable(i), usable(i + 1), leadingSpaces(lines[i].text) <= 3,
                  hasPipe(lines[i].text), hasPipe(lines[i + 1].text),
                  let alignments = delimiter(lines[i + 1].text)
            else { i += 1; continue }
            let header = cells(lines[i].text)
            guard header.count == alignments.count else { i += 1; continue }
            // Body: every following line with a pipe, up to a blank line or one without.
            var last = i + 1
            var rows: [[String]] = []
            while usable(last + 1), hasPipe(lines[last + 1].text),
                  !lines[last + 1].text.trimmingCharacters(in: .whitespaces).isEmpty {
                last += 1
                var row = cells(lines[last].text)
                if row.count > header.count { row.removeLast(row.count - header.count) }
                while row.count < header.count { row.append("") }
                rows.append(row)
            }
            let end = lines[last].start + (lines[last].text as NSString).length
            out.append(MarkdownTable(range: lines[i].start..<end, alignments: alignments, header: header, rows: rows))
            i = last + 1
        }
        return out
    }

    /// A row's cells: one outer `|` on each side dropped, split on the pipes that
    /// aren't escaped, each cell trimmed and its `\|` unescaped.
    static func cells(_ line: String) -> [String] {
        let units = Array(line.trimmingCharacters(in: .whitespaces).utf16)
        let pipe = UInt16(UnicodeScalar("|").value), backslash = UInt16(UnicodeScalar("\\").value)
        var lo = 0, hi = units.count
        if lo < hi, units[lo] == pipe { lo += 1 }
        if hi > lo, units[hi - 1] == pipe, hi - 2 < lo || units[hi - 2] != backslash { hi -= 1 }
        var out: [String] = []
        var cell: [UInt16] = []
        func flush() {
            let s = String(utf16CodeUnits: cell, count: cell.count)
            out.append(s.replacingOccurrences(of: "\\|", with: "|").trimmingCharacters(in: .whitespaces))
            cell.removeAll()
        }
        var k = lo
        while k < hi {
            if units[k] == pipe, k == 0 || units[k - 1] != backslash { flush() } else { cell.append(units[k]) }
            k += 1
        }
        flush()
        return out
    }

    /// The column alignments a delimiter row sets (`---`, `:--`, `:-:`, `--:`), or
    /// nil when `line` isn't one.
    static func delimiter(_ line: String) -> [MarkdownTable.Alignment]? {
        guard leadingSpaces(line) <= 3 else { return nil }
        var out: [MarkdownTable.Alignment] = []
        for cell in cells(line) {
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            let dashes = cell.dropFirst(left ? 1 : 0).dropLast(right && cell.count > 1 ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            out.append(left && right ? .center : left ? .left : right ? .right : .none)
        }
        return out
    }

    /// A cell's markdown as styled runs, markers dropped: `**b** and [[note|alias]]`
    /// → "b" (bold), " and ", "alias" (link). Block syntax means nothing in a cell,
    /// so only inline styles count.
    static func runs(_ cell: String) -> [CellRun] {
        let ns = cell as NSString
        guard ns.length > 0 else { return [] }
        var hidden = [Bool](repeating: false, count: ns.length)
        var styles = [CellRun.Style](repeating: [], count: ns.length)
        for span in InlineTokenizer.spans(in: cell) {
            let style: CellRun.Style
            switch span.style {
            case .bold: style = .bold
            case .italic: style = .italic
            case .inlineCode: style = .code
            case .link: style = .link
            case .tag: style = .tag
            default: continue
            }
            for k in span.content where k < ns.length { styles[k].insert(style) }
            for marker in span.markers { for k in marker where k < ns.length { hidden[k] = true } }
        }
        var out: [CellRun] = []
        var units: [UInt16] = []
        var current: CellRun.Style = []
        func flush() {
            guard !units.isEmpty else { return }
            out.append(CellRun(text: String(utf16CodeUnits: units, count: units.count), style: current))
            units.removeAll()
        }
        for k in 0..<ns.length where !hidden[k] {
            if styles[k] != current { flush(); current = styles[k] }
            units.append(ns.character(at: k))
        }
        flush()
        return out
    }

    /// Column widths for a table whose columns would like `ideal` widths, in
    /// `available` space: as wished when they fit, else narrow columns keep
    /// theirs and the wide ones share the rest equally (so one long cell
    /// wraps instead of squeezing every column).
    static func columnWidths(ideal: [Double], available: Double) -> [Double] {
        guard ideal.reduce(0, +) > available else { return ideal }
        var widths = ideal
        var remaining = available
        var open = Array(ideal.indices).sorted { ideal[$0] < ideal[$1] }
        while let narrowest = open.first {
            let share = remaining / Double(open.count)
            if ideal[narrowest] <= share {
                remaining -= ideal[narrowest]
                open.removeFirst()
            } else {
                for i in open { widths[i] = share }
                break
            }
        }
        return widths
    }

    private static func hasPipe(_ line: String) -> Bool {
        var previous: Character = " "
        for c in line {
            if c == "|" && previous != "\\" { return true }
            previous = c
        }
        return false
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }
}

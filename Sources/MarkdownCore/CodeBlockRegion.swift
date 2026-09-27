import Foundation

public struct CodeBlockRegion: Equatable {
    public let language: String        // "" if none
    public let body: Range<Int>        // inner text (between fences), UTF-16
    public let full: Range<Int>        // whole block incl fences
    public init(language: String, body: Range<Int>, full: Range<Int>) {
        self.language = language; self.body = body; self.full = full
    }
}

public enum CodeBlockParser {
    /// Finds fenced code blocks (``` or ~~~, see `Fence`). A block opens on a fence
    /// line (optionally followed by a language) and closes on a bare fence of the
    /// same marker at least as long.
    public static func regions(in text: String) -> [CodeBlockRegion] {
        var out: [CodeBlockRegion] = []
        let ns = text as NSString
        let length = ns.length
        let newline = UInt16(UnicodeScalar("\n").value)

        var lineStart = 0
        var open: (fenceStart: Int, bodyStart: Int, fence: Fence)? = nil
        while lineStart <= length {
            var lineEnd = lineStart
            while lineEnd < length && ns.character(at: lineEnd) != newline { lineEnd += 1 }
            let line = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            if let o = open {
                if o.fence.isClosed(by: line) {
                    let bodyEnd = lineStart > o.bodyStart ? lineStart - 1 : o.bodyStart
                    out.append(CodeBlockRegion(language: o.fence.info, body: o.bodyStart..<bodyEnd, full: o.fenceStart..<lineEnd))
                    open = nil
                }
            } else if let fence = Fence.opening(line) {
                let bodyStart = (lineEnd == length) ? lineEnd : lineEnd + 1
                open = (fenceStart: lineStart, bodyStart: bodyStart, fence: fence)
            }
            if lineEnd == length { break }
            lineStart = lineEnd + 1
        }
        return out
    }

    /// Everything that is code, as the tokenizer styles it: every closed block,
    /// plus a fence that hasn't been closed yet, running to the end of the
    /// document. That open state is exactly where you are while typing a new
    /// block, so "am I in code?" questions (list keys, tags, checkboxes) use this;
    /// only rendering a block needs `regions` and its closing fence.
    public static func codeRanges(in text: String) -> [Range<Int>] {
        let closed = regions(in: text).map(\.full)
        let ns = text as NSString
        let newline = UInt16(UnicodeScalar("\n").value)
        var lineStart = closed.last?.upperBound ?? 0
        if lineStart > 0 { lineStart += 1 }   // past the closing fence's newline
        while lineStart < ns.length {
            var lineEnd = lineStart
            while lineEnd < ns.length && ns.character(at: lineEnd) != newline { lineEnd += 1 }
            if Fence.opening(ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))) != nil {
                return closed + [lineStart..<ns.length]
            }
            lineStart = lineEnd + 1
        }
        return closed
    }

    /// Fenced code (unclosed fences included) and inline code spans, as sorted,
    /// disjoint UTF-16 ranges — what links and tags must not be found in.
    public static func allCodeRanges(in text: String) -> [Range<Int>] {
        let ns = text as NSString
        let fences = codeRanges(in: text)
        let backtick = UInt16(UnicodeScalar("`").value), newline = UInt16(UnicodeScalar("\n").value)
        var inline: [Range<Int>] = []
        var fence = 0
        var i = 0
        while i < ns.length {
            while fence < fences.count, fences[fence].upperBound <= i { fence += 1 }
            if fence < fences.count, fences[fence].contains(i) { i = fences[fence].upperBound; continue }
            // One line (fences never start mid-line): its backtick runs, in order.
            var lineEnd = i
            while lineEnd < ns.length, ns.character(at: lineEnd) != newline { lineEnd += 1 }
            var runs: [Range<Int>] = []
            var j = i
            while j < lineEnd {
                guard ns.character(at: j) == backtick else { j += 1; continue }
                var r = j
                while r < lineEnd, ns.character(at: r) == backtick { r += 1 }
                runs.append(j..<r); j = r
            }
            // A run of n backticks opens a span that the next run of exactly n
            // closes. Runs grouped by length, each with a cursor, find that closer
            // without rescanning the line from every opener (a crafted line of
            // distinct-length runs made that superlinear).
            var byLength: [Int: [Int]] = [:]
            for (k, run) in runs.enumerated() { byLength[run.count, default: []].append(k) }
            var cursor: [Int: Int] = [:]
            var k = 0
            while k < runs.count {
                let n = runs[k].count
                let same = byLength[n]!
                var c = cursor[n] ?? 0
                while c < same.count, same[c] <= k { c += 1 }
                cursor[n] = c
                if c < same.count {
                    inline.append(runs[k].lowerBound..<runs[same[c]].upperBound)
                    k = same[c] + 1
                } else {
                    k += 1
                }
            }
            i = lineEnd + 1
        }
        return (fences + inline).sorted { $0.lowerBound < $1.lowerBound }
    }
}

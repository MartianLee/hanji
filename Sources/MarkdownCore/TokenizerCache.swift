import Foundation

/// `InlineTokenizer.spans`, remembered line by line. A line's spans depend only on
/// its text and the state the lines above hand it (inside frontmatter, a code
/// fence, a callout), so each line is cached under that pair. After an edit only
/// lines whose text or incoming state changed are tokenized again; the rest is a
/// hash lookup and a shift — and lines an edit didn't reach aren't looked at at
/// all (see `splice`). The same pass yields the note's code blocks, as
/// `CodeBlockParser` finds them.
///
/// Output is identical to `InlineTokenizer.spans(in:)` — the check group
/// TokenizerCache holds it to that across random edits.
public final class TokenizerCache {
    /// Closed fenced code blocks, as `CodeBlockParser.regions(in:)`.
    public private(set) var codeBlockRegions: [CodeBlockRegion] = []
    /// Everything that is code, as `CodeBlockParser.codeRanges(in:)`.
    public private(set) var codeRanges: [Range<Int>] = []

    private struct Key: Hashable {
        let line: String
        let opensFrontmatter: Bool
        let state: InlineTokenizer.LineState
        /// The fence as `CodeBlockParser` sees it (it doesn't know frontmatter),
        /// which decides where tags aren't, and its list context.
        let parserFence: Fence?
        let parserInList: Bool
    }
    private struct Entry {
        let spans: [MarkSpan]        // at line offset 0, tags aside
        let tags: [MarkSpan]
        let state: InlineTokenizer.LineState
        let parserFence: Fence?
        let parserInList: Bool
    }
    private var entries: [Key: Entry] = [:]

    /// The last text's lines, for splicing the next: each one's place (newline
    /// excluded), key and entry, and where its spans and tags start in the output.
    private struct Line {
        var start: Int, end: Int
        let key: Key, entry: Entry
        var spanIndex = 0, tagIndex = 0
    }
    private var lines: [Line] = []
    private var lastText: NSString?
    private var lastFrontmatter: Range<Int>?
    private var outSpans: [MarkSpan] = []
    private var outTags: [MarkSpan] = []

    public init() {}

    public func spans(in text: String) -> [MarkSpan] {
        let ns = text as NSString
        let frontmatter = Frontmatter.range(in: text)
        // After an edit, only the lines from the edit to where the line state
        // settles again are looked at; before that the last result stands, after
        // it the last result shifts. (Walking every line — a substring and a hash
        // each — cost ~7ms a keystroke at 20,000 lines.)
        let spliced = lastText.map { old in
            !lines.isEmpty && frontmatter == lastFrontmatter && splice(from: old, to: ns, frontmatter: frontmatter)
        } ?? false
        if !spliced { rebuild(ns, frontmatter: frontmatter) }
        lastText = ns
        lastFrontmatter = frontmatter
        findCodeBlocks(length: ns.length)
        // Keep what this text uses once the cache has grown well past it.
        if entries.count > 2 * lines.count + 1000 {
            var kept: [Key: Entry] = [:]
            for line in lines { kept[line.key] = entries[line.key] }
            entries = kept
        }
        return outSpans + outTags
    }

    /// The entry for a line, tokenized if it isn't cached.
    private func entry(for key: Key) -> Entry {
        if let hit = entries[key] { return hit }
        let entry = tokenize(key)
        entries[key] = entry
        return entry
    }

    /// Lines of `ns` from `lineStart` on, tokenized, until `stop` says a line
    /// (given its start, index and incoming state) needn't be — `stop` gets the
    /// state as (tokenizer state, parser fence, parser list context).
    private func scan(_ ns: NSString, from lineStart: Int, index: Int, frontmatter: Range<Int>?,
                      state initial: (InlineTokenizer.LineState, Fence?, Bool),
                      stop: (Int, Int, (InlineTokenizer.LineState, Fence?, Bool)) -> Bool) -> [Line] {
        let length = ns.length
        var out: [Line] = []
        var (state, parserFence, parserInList) = initial
        var pos = lineStart, lineIndex = index
        while pos <= length {
            if stop(pos, lineIndex, (state, parserFence, parserInList)) { break }
            var lineEnd = pos
            while lineEnd < length && ns.character(at: lineEnd) != 0x0A { lineEnd += 1 }
            let key = Key(line: ns.substring(with: NSRange(location: pos, length: lineEnd - pos)),
                          opensFrontmatter: lineIndex == 0 && frontmatter != nil,
                          state: state, parserFence: parserFence, parserInList: parserInList)
            let e = entry(for: key)
            out.append(Line(start: pos, end: lineEnd, key: key, entry: e))
            (state, parserFence, parserInList) = (e.state, e.parserFence, e.parserInList)
            if lineEnd == length { break }
            pos = lineEnd + 1
            lineIndex += 1
        }
        return out
    }

    /// Append `line`'s spans and tags to the output, noting where they start.
    private func emit(_ line: inout Line, spans: inout [MarkSpan], tags: inout [MarkSpan], frontmatter: Range<Int>?) {
        line.spanIndex = spans.count
        line.tagIndex = tags.count
        for span in line.entry.spans { spans.append(line.start == 0 ? span : span.shifted(by: line.start)) }
        if !(frontmatter.map { $0.contains(line.start) } ?? false) {
            for tag in line.entry.tags { tags.append(tag.shifted(by: line.start)) }
        }
    }

    private func rebuild(_ ns: NSString, frontmatter: Range<Int>?) {
        // First load: size the cache for the note at once rather than growing
        // (and rehashing) it line by line.
        if entries.isEmpty { entries.reserveCapacity(ns.length / 24 + 16) }
        lines = scan(ns, from: 0, index: 0, frontmatter: frontmatter,
                     state: (InlineTokenizer.LineState(), nil, false), stop: { _, _, _ in false })
        var spans: [MarkSpan] = [], tags: [MarkSpan] = []
        for i in lines.indices { emit(&lines[i], spans: &spans, tags: &tags, frontmatter: frontmatter) }
        outSpans = spans
        outTags = tags
    }

    /// Carry the last result over to `new`, re-tokenizing only the lines an edit
    /// reaches. false when it can't (the edit is in the frontmatter, whose extent
    /// every line's tags depend on) — then everything is rebuilt.
    private func splice(from old: NSString, to new: NSString, frontmatter: Range<Int>?) -> Bool {
        let (oldEdit, newEdit) = Self.changedRanges(old, new)
        if oldEdit.length == 0 && newEdit.length == 0 { return true }
        if let fm = frontmatter, oldEdit.location <= fm.upperBound { return false }
        let delta = new.length - old.length
        // The first line the edit touches (its newline counts as part of it).
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].start <= oldEdit.location { lo = mid } else { hi = mid - 1 }
        }
        let a = lo
        let incoming = a > 0 ? (lines[a - 1].entry.state, lines[a - 1].entry.parserFence, lines[a - 1].entry.parserInList)
                             : (InlineTokenizer.LineState(), nil, false)
        // Past the edit, a line that starts where an old one did (shifted) and
        // comes in with the same state is that old line, and so is every line
        // after it: stop there and reuse them.
        var resume: Int?
        let fresh = scan(new, from: lines[a].start, index: a, frontmatter: frontmatter, state: incoming) { pos, index, state in
            guard pos >= NSMaxRange(newEdit), index > 0 else { return false }
            let target = pos - delta
            var l = a, h = self.lines.count - 1
            while l < h {
                let m = (l + h) / 2
                if self.lines[m].start < target { l = m + 1 } else { h = m }
            }
            guard l < self.lines.count, self.lines[l].start == target, l > a || target > self.lines[a].start else { return false }
            let key = self.lines[l].key
            guard key.state == state.0, key.parserFence == state.1, key.parserInList == state.2, !key.opensFrontmatter else { return false }
            resume = l
            return true
        }
        var spans = Array(outSpans[0..<lines[a].spanIndex])
        var tags = Array(outTags[0..<lines[a].tagIndex])
        var result = Array(lines[0..<a])
        result.reserveCapacity(lines.count + fresh.count)
        for var line in fresh {
            emit(&line, spans: &spans, tags: &tags, frontmatter: frontmatter)
            result.append(line)
        }
        if let j = resume {
            let spanShift = spans.count - lines[j].spanIndex, tagShift = tags.count - lines[j].tagIndex
            if delta == 0 {
                spans.append(contentsOf: outSpans[lines[j].spanIndex...])
                tags.append(contentsOf: outTags[lines[j].tagIndex...])
            } else {
                spans.append(contentsOf: outSpans[lines[j].spanIndex...].lazy.map { $0.shifted(by: delta) })
                tags.append(contentsOf: outTags[lines[j].tagIndex...].lazy.map { $0.shifted(by: delta) })
            }
            for k in j..<lines.count {
                var line = lines[k]
                line.start += delta; line.end += delta
                line.spanIndex += spanShift; line.tagIndex += tagShift
                result.append(line)
            }
        }
        lines = result
        outSpans = spans
        outTags = tags
        return true
    }

    /// Code blocks, as the parser draws them, from each line's parser fence.
    private func findCodeBlocks(length: Int) {
        var regions: [CodeBlockRegion] = []
        var openRegion: (fenceStart: Int, bodyStart: Int, fence: Fence)?
        var parserFence: Fence?
        for line in lines {
            if parserFence == nil, let opened = line.entry.parserFence {
                openRegion = (line.start, line.end == length ? line.end : line.end + 1, opened)
            } else if parserFence != nil, line.entry.parserFence == nil, let o = openRegion {
                let bodyEnd = line.start > o.bodyStart ? line.start - 1 : o.bodyStart
                regions.append(CodeBlockRegion(language: o.fence.info, body: o.bodyStart..<bodyEnd,
                                               full: o.fenceStart..<line.end, indent: o.fence.indent))
                openRegion = nil
            }
            parserFence = line.entry.parserFence
        }
        codeBlockRegions = regions
        codeRanges = regions.map(\.full) + (openRegion.map { [$0.fenceStart..<length] } ?? [])
    }

    /// Where two texts differ: the common prefix and suffix trimmed off.
    static func changedRanges(_ old: NSString, _ new: NSString) -> (old: NSRange, new: NSRange) {
        let oldLength = old.length, newLength = new.length
        var a = [unichar](repeating: 0, count: oldLength)
        var b = [unichar](repeating: 0, count: newLength)
        old.getCharacters(&a, range: NSRange(location: 0, length: oldLength))
        new.getCharacters(&b, range: NSRange(location: 0, length: newLength))
        let shorter = min(oldLength, newLength)
        var prefix = 0
        while prefix < shorter && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix && a[oldLength - 1 - suffix] == b[newLength - 1 - suffix] { suffix += 1 }
        return (NSRange(location: prefix, length: oldLength - suffix - prefix),
                NSRange(location: prefix, length: newLength - suffix - prefix))
    }

    private func tokenize(_ key: Key) -> Entry {
        var state = key.state
        var spans: [MarkSpan] = []
        InlineTokenizer.tokenizeLine(key.line, at: 0, opensFrontmatter: key.opensFrontmatter,
                                     state: &state, into: &spans)
        // Tags, where the full-text scan would find them: not in code (by the
        // parser's fences, including this line's own fence), not in inline code.
        let lineRange = 0..<(key.line as NSString).length
        var parserFence = key.parserFence
        var parserInList = key.parserInList
        var inCode = parserFence != nil
        if let open = parserFence {
            if open.isClosed(by: key.line) {
                parserFence = nil
                parserInList = ListContext.after(key.line, inList: parserInList)
            }
        } else {
            if let fence = Fence.opening(key.line, inList: parserInList) {
                parserFence = fence
                inCode = true
            }
            parserInList = ListContext.after(key.line, inList: parserInList)
        }
        let tags = inCode ? [] : Tags.occurrences(in: key.line).map {
            MarkSpan(style: .tag, content: $0.range, markers: [], line: lineRange)
        }
        return Entry(spans: spans, tags: tags, state: state, parserFence: parserFence, parserInList: parserInList)
    }
}

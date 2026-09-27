import Foundation

/// `InlineTokenizer.spans`, remembered line by line. A line's spans depend only on
/// its text and the state the lines above hand it (inside frontmatter, a code
/// fence, a callout), so each line is cached under that pair. After an edit only
/// lines whose text or incoming state changed are tokenized again; the rest is a
/// hash lookup and a shift. The same pass yields the note's code blocks, as
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
        /// which decides where tags aren't.
        let parserFence: Fence?
    }
    private struct Entry {
        let spans: [MarkSpan]        // at line offset 0, tags aside
        let tags: [MarkSpan]
        let state: InlineTokenizer.LineState
        let parserFence: Fence?
    }
    private var entries: [Key: Entry] = [:]

    public init() {}

    public func spans(in text: String) -> [MarkSpan] {
        let ns = text as NSString
        let length = ns.length
        let newline = UInt16(UnicodeScalar("\n").value)
        let frontmatter = Frontmatter.range(in: text)
        // First load: size the cache for the note at once rather than growing
        // (and rehashing) it line by line.
        if entries.isEmpty { entries.reserveCapacity(length / 24 + 16) }

        var spans: [MarkSpan] = []
        var tags: [MarkSpan] = []
        var regions: [CodeBlockRegion] = []
        var used: [Key] = []
        used.reserveCapacity(entries.capacity)
        var state = InlineTokenizer.LineState()
        var parserFence: Fence?
        var openRegion: (fenceStart: Int, bodyStart: Int, info: String)?
        var lineStart = 0
        var lineIndex = 0
        while lineStart <= length {
            var lineEnd = lineStart
            while lineEnd < length && ns.character(at: lineEnd) != newline { lineEnd += 1 }
            let line = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            let key = Key(line: line, opensFrontmatter: lineIndex == 0 && frontmatter != nil,
                          state: state, parserFence: parserFence)
            let entry: Entry
            if let hit = entries[key] { entry = hit } else { entry = tokenize(key); entries[key] = entry }
            used.append(key)

            spans.append(contentsOf: lineStart == 0 ? entry.spans : entry.spans.map { $0.shifted(by: lineStart) })
            let inFrontmatter = frontmatter.map { $0.contains(lineStart) } ?? false
            if !inFrontmatter {
                tags.append(contentsOf: entry.tags.map { $0.shifted(by: lineStart) })
            }
            // Code blocks, as the parser draws them.
            if parserFence == nil, let opened = entry.parserFence {
                openRegion = (lineStart, lineEnd == length ? lineEnd : lineEnd + 1, opened.info)
            } else if parserFence != nil, entry.parserFence == nil, let o = openRegion {
                let bodyEnd = lineStart > o.bodyStart ? lineStart - 1 : o.bodyStart
                regions.append(CodeBlockRegion(language: o.info, body: o.bodyStart..<bodyEnd, full: o.fenceStart..<lineEnd))
                openRegion = nil
            }
            state = entry.state
            parserFence = entry.parserFence

            if lineEnd == length { break }
            lineStart = lineEnd + 1
            lineIndex += 1
        }
        codeBlockRegions = regions
        codeRanges = regions.map(\.full) + (openRegion.map { [$0.fenceStart..<length] } ?? [])
        // Keep what this text uses once the cache has grown well past it.
        if entries.count > 2 * used.count + 1000 {
            var kept: [Key: Entry] = [:]
            for key in used { kept[key] = entries[key] }
            entries = kept
        }
        return spans + tags
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
        var inCode = parserFence != nil
        if let open = parserFence {
            if open.isClosed(by: key.line) { parserFence = nil }
        } else if let fence = Fence.opening(key.line) {
            parserFence = fence
            inCode = true
        }
        let tags = inCode ? [] : Tags.occurrences(in: key.line).map {
            MarkSpan(style: .tag, content: $0.range, markers: [], line: lineRange)
        }
        return Entry(spans: spans, tags: tags, state: state, parserFence: parserFence)
    }
}

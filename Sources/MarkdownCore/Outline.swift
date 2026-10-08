import Foundation

/// A heading as the outline lists it.
public struct OutlineHeading: Equatable {
    /// 1...6, the number of `#`.
    public let level: Int
    /// The visible text: inline markers removed, a closing `#` run dropped.
    public let title: String
    /// UTF-16 offset of the heading line's start.
    public let offset: Int

    public init(level: Int, title: String, offset: Int) {
        self.level = level; self.title = title; self.offset = offset
    }
}

/// A note's headings, taken from the editor's own tokenizer so the outline
/// can't disagree with what the editor styles as a heading: fenced code
/// (unclosed fences too) and frontmatter hold none.
public enum Outline {
    public static func headings(in text: String) -> [OutlineHeading] {
        let ns = text as NSString
        let spans = InlineTokenizer.spans(in: text)
        // Grouped once: looking each heading's line up among all spans would be
        // quadratic in a long note, and the outline is rebuilt while typing.
        var markersByLine: [Range<Int>: [Range<Int>]] = [:]
        for span in spans {
            if case .heading = span.style { continue }
            markersByLine[span.line, default: []].append(contentsOf: span.markers)
        }
        return spans.compactMap { span in
            guard case .heading(let level) = span.style else { return nil }
            return OutlineHeading(level: level,
                                  title: title(of: span, markers: markersByLine[span.line] ?? [], in: ns),
                                  offset: span.line.lowerBound)
        }
    }

    /// The index of the heading whose section holds `offset` — the last one at
    /// or before it; nil before the first heading.
    public static func current(in headings: [OutlineHeading], at offset: Int) -> Int? {
        headings.lastIndex { $0.offset <= offset }
    }

    /// The heading's content without the markers of the other spans on its line
    /// (`**`, `[[target|`, backticks), trimmed, and without a closing `#` run.
    private static func title(of heading: MarkSpan, markers lineMarkers: [Range<Int>], in ns: NSString) -> String {
        let content = heading.content
        let text = NSMutableString(string: ns.substring(with: NSRange(location: content.lowerBound,
                                                                      length: content.count)))
        let markers = lineMarkers
            .compactMap { m -> Range<Int>? in
                let lo = max(m.lowerBound, content.lowerBound), hi = min(m.upperBound, content.upperBound)
                return lo < hi ? (lo - content.lowerBound)..<(hi - content.lowerBound) : nil
            }
            .sorted { $0.lowerBound > $1.lowerBound }
        for m in markers { text.deleteCharacters(in: NSRange(location: m.lowerBound, length: m.count)) }
        var title = (text as String).trimmingCharacters(in: .whitespaces)
        if let closing = title.range(of: #"(^|\s+)#+$"#, options: .regularExpression) {
            title.removeSubrange(closing)
        }
        return title
    }
}

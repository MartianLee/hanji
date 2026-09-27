import Foundation

public enum SpanStyle: Equatable {
    case heading(Int)   // 1...6
    case bold
    case italic
    case inlineCode
    case link
    case blockquote
    case frontmatter
    case listItem
    case orderedItem  // `1. ` / `2) ` — the number stays visible, it *is* the marker
    case task(Bool)   // done?
    case codeBlock
    case callout
    case tag          // `#tag` (see Tags.occurrences); no markers to hide
}

/// A recognized markdown construct, in UTF-16 code-unit offsets (NSRange-compatible).
public struct MarkSpan: Equatable {
    /// The same span `delta` code units further along.
    public func shifted(by delta: Int) -> MarkSpan {
        func move(_ r: Range<Int>) -> Range<Int> { (r.lowerBound + delta)..<(r.upperBound + delta) }
        return MarkSpan(style: style, content: move(content), markers: markers.map(move), line: move(line))
    }

    public let style: SpanStyle
    public let content: Range<Int>      // visible content
    public let markers: [Range<Int>]    // syntax marker ranges (candidates to hide)
    public let line: Range<Int>         // enclosing line (for caret-aware reveal)
    public init(style: SpanStyle, content: Range<Int>, markers: [Range<Int>], line: Range<Int>) {
        self.style = style
        self.content = content
        self.markers = markers
        self.line = line
    }
}

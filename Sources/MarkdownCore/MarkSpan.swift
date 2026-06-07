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
    case task(Bool)   // done?
}

/// A recognized markdown construct, in UTF-16 code-unit offsets (NSRange-compatible).
public struct MarkSpan: Equatable {
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

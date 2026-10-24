import Foundation
import MarkdownCore

/// What a click in the note acts on — links, `#tags`, footnote marks — kept
/// until the text changes: the pointer asks on every move.
final class ClickTargets {
    private var text: NSString?
    private var links: [LinkRef] = []
    private var others: [Range<Int>] = []

    /// The link a click at `offset` follows, as `handleClick` finds it.
    func link(at offset: Int, in text: NSString) -> LinkRef? {
        refresh(text)
        return links.first { $0.range.lowerBound <= offset && offset < $0.range.upperBound }
    }

    func isClickable(at offset: Int, in text: NSString) -> Bool {
        link(at: offset, in: text) != nil || others.contains { $0.contains(offset) }
    }

    private func refresh(_ current: NSString) {
        if let text, text.isEqual(to: current as String) { return }
        text = current.copy() as? NSString
        let s = current as String
        links = LinkParser.links(in: s)
        let footnotes = InlineTokenizer.spans(in: s).compactMap { span -> Range<Int>? in
            switch span.style {
            case .footnoteRef: return span.markers[0].lowerBound..<span.markers[1].upperBound
            case .footnoteDef: return span.content
            default: return nil
            }
        }
        others = Tags.occurrences(in: s).map(\.range) + footnotes
    }
}

import Foundation

/// Where a click on a footnote goes: from a reference `[^id]` to the line
/// defining it, and from a definition's `[^id]:` back to the first reference.
public enum Footnotes {
    /// The offset to jump to from a click at `offset`, or nil when the click
    /// isn't on a footnote or the other end doesn't exist.
    public static func jumpTarget(at offset: Int, in text: String) -> Int? {
        let ns = text as NSString
        let notes = InlineTokenizer.spans(in: text).filter { $0.style == .footnoteRef || $0.style == .footnoteDef }
        func whole(_ s: MarkSpan) -> Range<Int> {
            s.style == .footnoteRef ? s.markers[0].lowerBound..<s.markers[1].upperBound : s.content
        }
        func id(_ s: MarkSpan) -> String {
            let r = s.style == .footnoteRef ? s.content : (s.content.lowerBound + 2)..<(s.content.upperBound - 2)
            return ns.substring(with: NSRange(location: r.lowerBound, length: r.count))
        }
        guard let hit = notes.first(where: { whole($0).contains(offset) }) else { return nil }
        let key = id(hit)
        let other: SpanStyle = hit.style == .footnoteRef ? .footnoteDef : .footnoteRef
        return notes.first { $0.style == other && id($0) == key }.map { whole($0).lowerBound }
    }
}

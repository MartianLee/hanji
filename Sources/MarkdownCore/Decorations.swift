import Foundation

public struct StyleRun: Equatable {
    public let range: Range<Int>
    public let style: SpanStyle
    public init(range: Range<Int>, style: SpanStyle) { self.range = range; self.style = style }
}

public struct DecorationSet: Equatable {
    public var styles: [StyleRun]
    public var hidden: [Range<Int>]
    public init(styles: [StyleRun] = [], hidden: [Range<Int>] = []) {
        self.styles = styles; self.hidden = hidden
    }
}

extension DecorationSet {
    /// The decorations inside `range`, cut to it and moved to start at 0 — for
    /// restyling one stretch of a document on its own.
    public func clipped(to range: Range<Int>) -> DecorationSet {
        func clip(_ r: Range<Int>) -> Range<Int>? {
            let lo = max(r.lowerBound, range.lowerBound), hi = min(r.upperBound, range.upperBound)
            return lo < hi ? (lo - range.lowerBound)..<(hi - range.lowerBound) : nil
        }
        return DecorationSet(styles: styles.compactMap { run in clip(run.range).map { StyleRun(range: $0, style: run.style) } },
                             hidden: hidden.compactMap(clip))
    }
}

public enum Decorator {
    /// Pure: spans + caret/selection (UTF-16 offsets) -> style runs + marker ranges to hide.
    /// A span's markers are hidden unless the selection intersects the span's line;
    /// with no selection (reading mode) every line hides them.
    public static func decorations(spans: [MarkSpan], selection: Range<Int>?) -> DecorationSet {
        var styles: [StyleRun] = []
        var hidden: [Range<Int>] = []
        for span in spans {
            let lowers = span.markers.map(\.lowerBound) + [span.content.lowerBound]
            let uppers = span.markers.map(\.upperBound) + [span.content.upperBound]
            let full = lowers.min()! ..< uppers.max()!
            styles.append(StyleRun(range: full, style: span.style))
            if !(selection.map { intersects(span.line, $0) } ?? false) {
                hidden.append(contentsOf: span.markers)
            }
        }
        return DecorationSet(styles: styles, hidden: hidden)
    }

    /// Inclusive overlap so a caret resting at a line boundary counts as "on the line".
    static func intersects(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        a.lowerBound <= b.upperBound && b.lowerBound <= a.upperBound
    }
}

import AppKit
import MarkdownCore
import EditorEngine

func listTaskStylerChecks() {
    let text = "- [x] done\n- item"
    let storage = NSTextStorage(string: text)
    let spans = InlineTokenizer.spans(in: text)
    LivePreviewStyler.apply(Decorator.decorations(spans: spans, selection: 100..<100), to: storage)

    // completed task text 'done' at offset 6 -> strikethrough
    let d = storage.attributes(at: 6, effectiveRange: nil)
    expect(d[.strikethroughStyle] != nil, "completed task text struck through")

    // list item 'item' at offset 13 -> hanging indent (paragraph style)
    let l = storage.attributes(at: 13, effectiveRange: nil)
    let p = l[.paragraphStyle] as? NSParagraphStyle
    expect(p != nil && p!.headIndent > 0, "list item indented")

    // checkbox itself (offset 0) should NOT be struck through
    let box = storage.attributes(at: 0, effectiveRange: nil)
    expect(box[.strikethroughStyle] == nil, "checkbox not struck through")

    // An ordered item's hanging indent is measured from the font, so a wrapped
    // line still lands after the number when the user changes the editor size.
    func orderedIndent(at size: CGFloat) -> CGFloat {
        LivePreviewStyler.baseFontSize = size
        let src = "1. numbered item"
        let s = NSTextStorage(string: src)
        LivePreviewStyler.apply(Decorator.decorations(spans: InlineTokenizer.spans(in: src),
                                                      selection: 100..<100), to: s)
        let style = s.attributes(at: 3, effectiveRange: nil)[.paragraphStyle] as? NSParagraphStyle
        return style?.headIndent ?? 0
    }
    let small = orderedIndent(at: 15)
    let large = orderedIndent(at: 30)
    LivePreviewStyler.baseFontSize = 15   // leave the shared default as we found it
    expect(small > 15 && small < 45, "ordered indent is about a '10. ' wide at 15pt (got \(small))")
    expect(large > small * 1.5, "ordered indent scales with the font size (\(small) → \(large))")
}

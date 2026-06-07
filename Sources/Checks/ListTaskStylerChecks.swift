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
}

import AppKit
import MarkdownCore
import EditorEngine

func calloutStylerChecks() {
    let text = "> [!note] Hi\n> body"
    let storage = NSTextStorage(string: text)
    let spans = InlineTokenizer.spans(in: text)
    LivePreviewStyler.apply(Decorator.decorations(spans: spans, selection: 100..<100), to: storage)
    // header content 'Hi' at offset 10 -> callout background tint
    let a = storage.attributes(at: 10, effectiveRange: nil)
    expect(a[.backgroundColor] != nil, "callout has background tint")
}

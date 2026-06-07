import AppKit
import MarkdownCore
import EditorEngine

func linkStylerChecks() {
    let text = "see [docs](http://x) and [[Note]]"
    let storage = NSTextStorage(string: text)
    let spans = InlineTokenizer.spans(in: text)
    let end = (text as NSString).length
    LivePreviewStyler.apply(Decorator.decorations(spans: spans, selection: end..<end), to: storage)

    // 'd' of "docs" is at offset 5 -> link content, underlined link color
    let attrs = storage.attributes(at: 5, effectiveRange: nil)
    expect(attrs[.underlineStyle] != nil, "link content is underlined")
    expect((attrs[.foregroundColor] as? NSColor) == NSColor.linkColor, "link content uses link color")
}

import AppKit
import MarkdownCore
import EditorEngine

// Headless integration check: tokenize -> decorate -> apply on a real NSTextStorage,
// exercising the NSRange-clamping path without a running app / window.
func stylerChecks() {
    let text = "# Title\nThis is **bold** and *italic* and `code`."
    let storage = NSTextStorage(string: text)
    let spans = InlineTokenizer.spans(in: text)
    let end = (text as NSString).length
    let deco = Decorator.decorations(spans: spans, selection: end..<end)

    LivePreviewStyler.apply(deco, to: storage)

    expectEqual(storage.length, end, "apply changes attributes only, not text length")

    // Heading content ('T' at offset 2) should use a large font.
    let headingFont = storage.attributes(at: 2, effectiveRange: nil)[.font] as? NSFont
    expect(headingFont != nil && headingFont!.pointSize >= 20, "heading content uses a large font")

    // A hidden marker ('#' at offset 0, caret away) should use a near-zero font.
    let markerFont = storage.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont
    expect(markerFont != nil && markerFont!.pointSize < 1, "off-line marker collapsed to near-zero font")
}

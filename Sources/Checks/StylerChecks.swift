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

    // Reading rhythm: body text carries the roomier line height + paragraph gap.
    let bodyParagraph = storage.attributes(at: 9, effectiveRange: nil)[.paragraphStyle] as? NSParagraphStyle
    expect(bodyParagraph != nil && abs(bodyParagraph!.lineHeightMultiple - 1.3) < 0.01,
           "body line height multiple applied")
    expect(bodyParagraph != nil && bodyParagraph!.paragraphSpacing == 6, "paragraph gap applied")

    // Trait composition: bold inside a heading keeps the heading size.
    let h = "# A **b** c"
    let hs = NSTextStorage(string: h)
    LivePreviewStyler.apply(Decorator.decorations(spans: InlineTokenizer.spans(in: h),
                                                  selection: 100..<100), to: hs)
    let boldFont = hs.attributes(at: 6, effectiveRange: nil)[.font] as? NSFont   // 'b'
    expect(boldFont != nil && boldFont!.pointSize >= 26, "bold in heading keeps heading size")
    expect(boldFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false,
           "bold trait applied")

    // Inline code inside a heading: mono + near-heading size + background.
    let ch = "## A `cd` B"
    let chs = NSTextStorage(string: ch)
    LivePreviewStyler.apply(Decorator.decorations(spans: InlineTokenizer.spans(in: ch),
                                                  selection: 100..<100), to: chs)
    let codeAttrs = chs.attributes(at: 6, effectiveRange: nil)   // 'c'
    let codeFont = codeAttrs[.font] as? NSFont
    expect(codeFont != nil && codeFont!.pointSize >= 20, "heading inline code keeps heading-ish size")
    expect(codeAttrs[.backgroundColor] != nil, "heading inline code shaded")
}

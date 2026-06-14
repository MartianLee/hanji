import AppKit
import MarkdownCore
import EditorEngine

func codeBlockStylerChecks() {
    let text = "```\nlet x = 1\n```"
    let storage = NSTextStorage(string: text)
    let spans = InlineTokenizer.spans(in: text)
    LivePreviewStyler.apply(Decorator.decorations(spans: spans, selection: 100..<100), to: storage)

    // 'let' at offset 4 -> code region. The slab background is drawn by the
    // layout fragment (full width), NOT as a per-glyph attribute — per-glyph
    // backgrounds left gaps between lines and fences.
    let a = storage.attributes(at: 4, effectiveRange: nil)
    expect(a[.backgroundColor] == nil, "no per-glyph background (slab fill instead)")
    let f = a[.font] as? NSFont
    expect(f != nil && f!.pointSize == 14, "code block uses the mono code font size")

    // Body rhythm: the full text carries the roomier line height + paragraph gap.
    let p = storage.attributes(at: 4, effectiveRange: nil)[.paragraphStyle] as? NSParagraphStyle
    expect(p != nil && abs(p!.lineHeightMultiple - 1.2) < 0.01, "code block uses its own line height")
}

func codeHighlightStylerChecks() {
    let text = "```swift\nlet x = 1\n```"
    let storage = NSTextStorage(string: text)
    let spans = InlineTokenizer.spans(in: text)
    LivePreviewStyler.apply(Decorator.decorations(spans: spans, selection: 100..<100), to: storage)
    LivePreviewStyler.highlightCode(CodeBlockParser.regions(in: text), in: storage)

    // 'let' starts at offset 9 (after "```swift\n"); it must carry a non-default
    // foreground color (keyword color) and stay monospaced.
    let attrs = storage.attributes(at: 9, effectiveRange: nil)
    let color = attrs[.foregroundColor] as? NSColor
    expect(color != nil && color != NSColor.textColor, "keyword got a syntax color")
    let font = attrs[.font] as? NSFont
    expect(font?.isFixedPitch == true, "code stays monospaced under highlighting")
}

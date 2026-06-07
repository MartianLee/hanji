import AppKit
import MarkdownCore
import EditorEngine

func blockStylerChecks() {
    let text = "---\nk: v\n---\n> quoted line"
    let storage = NSTextStorage(string: text)
    let spans = InlineTokenizer.spans(in: text)
    LivePreviewStyler.apply(Decorator.decorations(spans: spans, selection: 0..<0), to: storage)

    // frontmatter 'k' at offset 4 -> tertiary color
    let fm = storage.attributes(at: 4, effectiveRange: nil)
    expect((fm[.foregroundColor] as? NSColor) == NSColor.tertiaryLabelColor, "frontmatter dimmed")

    // blockquote content 'quoted' at offset 15 -> indented paragraph style
    let bq = storage.attributes(at: 15, effectiveRange: nil)
    let p = bq[.paragraphStyle] as? NSParagraphStyle
    expect(p != nil && p!.headIndent > 0, "blockquote indented")
}

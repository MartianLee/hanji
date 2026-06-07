import AppKit
import MarkdownCore
import EditorEngine

func codeBlockStylerChecks() {
    let text = "```\nlet x = 1\n```"
    let storage = NSTextStorage(string: text)
    let spans = InlineTokenizer.spans(in: text)
    LivePreviewStyler.apply(Decorator.decorations(spans: spans, selection: 100..<100), to: storage)

    // 'let' at offset 4 -> background-shaded code region
    let a = storage.attributes(at: 4, effectiveRange: nil)
    expect(a[.backgroundColor] != nil, "code block has background")
    let f = a[.font] as? NSFont
    expect(f != nil && f!.pointSize == 13, "code block uses the mono code font size")
}

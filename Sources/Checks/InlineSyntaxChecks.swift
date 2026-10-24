import AppKit
import MarkdownCore
import EditorEngine

private func styles(_ text: String) -> [SpanStyle] { InlineTokenizer.spans(in: text).map(\.style) }

func inlineSyntaxChecks() {
    let s = InlineTokenizer.spans(in: "a ~~gone~~ b")
    expectEqual(s.first?.style, .strikethrough, "~~x~~ is struck")
    expectEqual(s.first?.content, 4..<8, "struck content 'gone'")
    expectEqual(s.first?.markers, [2..<4, 8..<10], "markers are the two ~~")
    let h = InlineTokenizer.spans(in: "==hi==")
    expectEqual(h.first?.style, .highlight, "==x== is highlighted")
    expectEqual(h.first?.markers, [0..<2, 4..<6], "markers are the two ==")
    expectEqual(styles("if a == b == c"), [], "== around spaces is not a highlight")
    expectEqual(styles("~~ a ~~"), [], "~~ around spaces is not struck")
    expectEqual(styles("~~~\ncode\n~~~"), [.codeBlock, .codeBlock, .codeBlock], "~~~ still opens a fence")
    expectEqual(styles("`~~no~~`"), [.inlineCode], "no strike inside inline code")

    let m = InlineTokenizer.spans(in: "area $\\pi r^2$ here")
    expectEqual(m.first?.style, .math, "$x$ is math")
    expectEqual(m.first?.content, 6..<13, "math content")
    expectEqual(m.first?.markers, [5..<6, 13..<14], "markers are the two $")
    expectEqual(styles("costs $5 and $10"), [], "$5 and $10 is money, not math")
    expectEqual(styles("$ x$"), [], "no space after the opening $")
    expectEqual(styles("$x $"), [], "no space before the closing $")
    expectEqual(styles("\\$x$"), [], "an escaped $ opens nothing")
    expectEqual(styles("`$x$`"), [.inlineCode], "no math in inline code")
    let d = InlineTokenizer.spans(in: "$$e=mc^2$$")
    expectEqual(d.first?.style, .math, "$$x$$ on one line is inline math")
    expectEqual(d.first?.markers, [0..<2, 8..<10], "its markers are the two $$")

    let r = InlineTokenizer.spans(in: "Fact[^1] here")
    expectEqual(r.first?.style, .footnoteRef, "[^1] mid-line is a reference")
    expectEqual(r.first?.content, 6..<7, "the id shows")
    expectEqual(r.first?.markers, [4..<6, 7..<8], "[^ and ] hide")
    let def = InlineTokenizer.spans(in: "[^1]: The note **b**")
    expectEqual(def.first?.style, .footnoteDef, "[^1]: at line start is a definition")
    expectEqual(def.first?.content, 0..<5, "the label is the definition span")
    expectEqual(def.first?.markers, [], "the label stays visible")
    expect(def.contains { $0.style == .bold }, "the definition's text is styled inline")
    expect(LinkParser.links(in: "x[^1] and [^1]: y").isEmpty, "footnotes are not links")
    expectEqual(styles("[^ 1]"), [], "no blanks in an id")

    let runs = TableParser.runs("~~x~~ ==y==")
    expectEqual(runs.map(\.text), ["x", " ", "y"], "cell markers dropped")
    expect(runs.count == 3 && runs[0].style.contains(.strike) && runs[2].style.contains(.highlight),
           "cell runs carry strike/highlight")
}

func inlineSyntaxStylerChecks() {
    let text = "~~a~~ ==b==\nnext"
    let storage = NSTextStorage(string: text)
    let end = (text as NSString).length
    LivePreviewStyler.apply(Decorator.decorations(spans: InlineTokenizer.spans(in: text), selection: end..<end), to: storage)
    expectEqual(storage.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) as? Int,
                NSUnderlineStyle.single.rawValue, "struck text has a strikethrough")
    expect(storage.attribute(.backgroundColor, at: 8, effectiveRange: nil) != nil, "highlighted text has a wash")
    expect(((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 99) < 1,
           "~~ hidden off the caret's line")

    let mt = "x $y$\nz"
    let ms = NSTextStorage(string: mt)
    LivePreviewStyler.apply(Decorator.decorations(spans: InlineTokenizer.spans(in: mt), selection: 7..<7), to: ms)
    let mf = ms.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
    expect(mf?.fontName.hasPrefix("STIX") == true || mf?.fontDescriptor.symbolicTraits.contains(.italic) == true,
           "math is set in STIX italic")
}

func footnoteChecks() {
    let text = "One[^a] two[^b].\n\n[^a]: First.\n[^b]: Second."
    let ns = text as NSString
    let defA = ns.range(of: "[^a]:").location, defB = ns.range(of: "[^b]:").location
    expectEqual(Footnotes.jumpTarget(at: 5, in: text), defA, "a reference jumps to its definition line")
    expectEqual(Footnotes.jumpTarget(at: 13, in: text), defB, "each reference finds its own definition")
    expectEqual(Footnotes.jumpTarget(at: defA + 1, in: text), 3, "a definition's label jumps back to the first reference")
    expectEqual(Footnotes.jumpTarget(at: 0, in: text), nil, "plain text jumps nowhere")
    expectEqual(Footnotes.jumpTarget(at: 4, in: "x[^z] y"), nil, "a reference with no definition jumps nowhere")
}

func mathFenceChecks() {
    let text = "a\n$$\nx^2 #notatag\n$$\nb"
    let regions = CodeBlockParser.regions(in: text)
    expectEqual(regions.map(\.language), ["math"], "a $$ block is a math region")
    expectEqual(regions.first.map { $0.bodyText(in: text as NSString) }, "x^2 #notatag", "its body is the formula")
    expect(Tags.occurrences(in: text).isEmpty, "no tags inside math")
    expectEqual(styles("$$\n**x**\n$$"), [.codeBlock, .codeBlock, .codeBlock], "math lines aren't markdown")
    expectEqual(CodeBlockParser.regions(in: "```math\nx\n```").map(\.language), ["math"], "```math is math too")
    expectEqual(CodeBlockParser.regions(in: "$$\nx\n").count, 0, "an unclosed $$ renders nothing")
    expectEqual(CodeBlockParser.codeRanges(in: "$$\nx\n").count, 1, "but is code while being typed")
    expectEqual(CodeBlockParser.regions(in: "$$ \nx\n$$\r").count, 1, "trailing blanks and CR are fine")
    expect(Fence.opening("$$$") == nil && Fence.opening("$$ x") == nil, "only a bare $$ is a fence")
    expect(CodeHighlighter.tokens(in: "x = 2 + \"y\"", language: "math").isEmpty, "math source isn't syntax-colored")
}

import MarkdownCore

func tokenizerChecks() {
    // Heading
    let h = InlineTokenizer.spans(in: "# Hi")
    expectEqual(h.count, 1, "one heading span")
    expectEqual(h.first?.style, .heading(1), "heading level 1")
    expectEqual(h.first?.content, 2..<4, "heading content after '# '")
    expectEqual(h.first?.markers, [0..<2], "heading marker is '# '")

    // Bold inside a line
    let b = InlineTokenizer.spans(in: "a **b** c")
    expectEqual(b.count, 1, "one bold span")
    expectEqual(b.first?.style, .bold, "bold style")
    expectEqual(b.first?.content, 4..<5, "bold content 'b'")
    expectEqual(b.first?.markers, [2..<4, 5..<7], "bold markers '**' x2")

    // Italic (single star), not confused with bold
    let i = InlineTokenizer.spans(in: "*i*")
    expectEqual(i.first?.style, .italic, "italic style")
    expectEqual(i.first?.content, 1..<2, "italic content")
    expectEqual(i.first?.markers, [0..<1, 2..<3], "italic markers '*' x2")

    // Inline code
    let c = InlineTokenizer.spans(in: "x `y` z")
    expectEqual(c.first?.style, .inlineCode, "inline code style")
    expectEqual(c.first?.content, 3..<4, "code content 'y'")
    expectEqual(c.first?.markers, [2..<3, 4..<5], "code backtick markers")

    // Multi-line: line ranges track the second line
    let m = InlineTokenizer.spans(in: "x\n**b**")
    expectEqual(m.count, 1, "one span on line 2")
    expectEqual(m.first?.content, 4..<5, "content offset accounts for first line + newline")
    expectEqual(m.first?.line, 2..<7, "line range is the second line")
}

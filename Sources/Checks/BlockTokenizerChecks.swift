import MarkdownCore

func blockTokenizerChecks() {
    let q = InlineTokenizer.spans(in: "> quote")
    expectEqual(q.count, 1, "one blockquote span")
    expectEqual(q.first?.style, .blockquote, "blockquote style")
    expectEqual(q.first?.content, 2..<7, "content after '> '")
    expectEqual(q.first?.markers, [0..<2], "marker '> '")

    let fm = InlineTokenizer.spans(in: "---\ntitle: x\n---\n# H")
    expectEqual(fm.filter { $0.style == .frontmatter }.count, 3, "three frontmatter lines incl fences")
    expectEqual(fm.contains { $0.style == .heading(1) }, true, "heading after frontmatter parsed normally")

    let notfm = InlineTokenizer.spans(in: "x\n---")
    expectEqual(notfm.contains { $0.style == .frontmatter }, false, "--- mid-doc is not frontmatter")
}

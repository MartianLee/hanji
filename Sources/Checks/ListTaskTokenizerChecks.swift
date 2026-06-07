import MarkdownCore

func listTaskTokenizerChecks() {
    let u = InlineTokenizer.spans(in: "- item")
    expectEqual(u.first?.style, .listItem, "dash list item")
    expectEqual(u.first?.content, 2..<6, "list content after '- '")

    let s = InlineTokenizer.spans(in: "* bullet")
    expectEqual(s.first?.style, .listItem, "star list item")

    let open = InlineTokenizer.spans(in: "- [ ] todo")
    expectEqual(open.first?.style, .task(false), "open task")
    expectEqual(open.first?.content, 6..<10, "task content after '- [ ] '")

    let done = InlineTokenizer.spans(in: "- [x] done")
    expectEqual(done.first?.style, .task(true), "done task")

    let it = InlineTokenizer.spans(in: "*italic*")
    expectEqual(it.first?.style, .italic, "no-space star is italic, not a list")
}

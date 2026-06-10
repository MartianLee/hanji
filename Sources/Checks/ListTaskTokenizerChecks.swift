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

    // Inline styles render INSIDE bullets/tasks (regression: were skipped).
    let boldInBullet = InlineTokenizer.spans(in: "- **a** b")
    expect(boldInBullet.contains { $0.style == .listItem }, "bullet recognized")
    expect(boldInBullet.contains { $0.style == .bold }, "bold inside bullet")
    let linkInTask = InlineTokenizer.spans(in: "- [ ] see [[Note]]")
    expect(linkInTask.contains { $0.style == .link }, "wikilink inside task")

    // Indented bullets are still bullets.
    let nested = InlineTokenizer.spans(in: "  - nested")
    expect(nested.contains { $0.style == .listItem }, "indented bullet recognized")

    // Headings scan inline too (code keeps composing in the styler).
    let codeInHeading = InlineTokenizer.spans(in: "## A `c` B")
    expect(codeInHeading.contains { $0.style == .inlineCode }, "inline code inside heading")
}

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

    // Ordered list items. The number is the marker readers see, so unlike `- `
    // it is never hidden — it just gets the list paragraph shape.
    let one = InlineTokenizer.spans(in: "1. first")
    expectEqual(one.first?.style, .orderedItem, "dot-numbered item")
    expectEqual(one.first?.content, 3..<8, "ordered content after '1. '")

    let paren = InlineTokenizer.spans(in: "2) second")
    expectEqual(paren.first?.style, .orderedItem, "paren-numbered item")
    expectEqual(paren.first?.content, 3..<9, "ordered content after '2) '")

    let big = InlineTokenizer.spans(in: "42. answer")
    expectEqual(big.first?.style, .orderedItem, "multi-digit item")
    expectEqual(big.first?.content, 4..<10, "ordered content after '42. '")

    let indented = InlineTokenizer.spans(in: "  3. nested")
    expect(indented.contains { $0.style == .orderedItem }, "indented ordered item recognized")

    let boldInOrdered = InlineTokenizer.spans(in: "1. **a** b")
    expect(boldInOrdered.contains { $0.style == .orderedItem }, "ordered item recognized")
    expect(boldInOrdered.contains { $0.style == .bold }, "bold inside an ordered item")

    // Near-misses stay plain text.
    expect(!InlineTokenizer.spans(in: "1.no space").contains { $0.style == .orderedItem },
           "digit-dot without a space is not a list")
    expect(!InlineTokenizer.spans(in: "2026. was a year").contains { $0.style == .listItem },
           "a year-like prefix is not a bullet")
}

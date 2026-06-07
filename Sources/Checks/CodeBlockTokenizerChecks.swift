import MarkdownCore

func codeBlockTokenizerChecks() {
    let spans = InlineTokenizer.spans(in: "before\n```swift\nlet x = 1\n```\nafter")
    expectEqual(spans.filter { $0.style == .codeBlock }.count, 3, "fence + body + fence = 3 codeBlock lines")
    expect(spans.contains { $0.style == .heading(1) } == false, "no heading parsing inside fences")

    let open = InlineTokenizer.spans(in: "```\nx")
    expectEqual(open.filter { $0.style == .codeBlock }.count, 2, "unclosed fence styles following lines")

    let h = InlineTokenizer.spans(in: "```\n# H\n```")
    expect(h.contains { $0.style == .codeBlock }, "code block recognized")
    expect(h.contains { if case .heading = $0.style { return true } else { return false } } == false,
           "hash inside fence is code, not heading")
}

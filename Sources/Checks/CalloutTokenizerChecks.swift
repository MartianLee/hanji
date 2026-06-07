import MarkdownCore

func calloutTokenizerChecks() {
    let c = InlineTokenizer.spans(in: "> [!note] Title\n> body\nplain")
    let callouts = c.filter { $0.style == .callout }
    expectEqual(callouts.count, 2, "header + body line are callout")
    expectEqual(callouts.first?.markers, [0..<2], "'> ' marker hidden off-line")

    let bq = InlineTokenizer.spans(in: "> just a quote")
    expect(bq.contains { $0.style == .callout } == false, "plain blockquote is not a callout")
    expect(bq.contains { $0.style == .blockquote }, "it's a blockquote")
}

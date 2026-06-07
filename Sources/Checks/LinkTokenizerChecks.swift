import MarkdownCore

func linkTokenizerChecks() {
    let l = InlineTokenizer.spans(in: "[text](url)")
    expectEqual(l.count, 1, "one link span")
    expectEqual(l.first?.style, .link, "link style")
    expectEqual(l.first?.content, 1..<5, "link content 'text'")
    expectEqual(l.first?.markers, [0..<1, 5..<11], "link markers '[' and '](url)'")

    let w = InlineTokenizer.spans(in: "[[Page]]")
    expectEqual(w.first?.style, .link, "wikilink is a link")
    expectEqual(w.first?.content, 2..<6, "wikilink content 'Page'")
    expectEqual(w.first?.markers, [0..<2, 6..<8], "wikilink markers '[[' and ']]'")

    let a = InlineTokenizer.spans(in: "[[Page|Alias]]")
    expectEqual(a.first?.content, 7..<12, "aliased wikilink shows alias")
    expectEqual(a.first?.markers, [0..<2, 2..<7, 12..<14], "markers '[[', 'Page|', ']]'")

    let b = InlineTokenizer.spans(in: "**b** [x](y)")
    expectEqual(b.count, 2, "bold + link on one line")
    expectEqual(b.last?.style, .link, "second span is the link")
}

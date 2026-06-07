import MarkdownCore

func codeBlockRegionChecks() {
    let r = CodeBlockParser.regions(in: "a\n```card\nhello\n```\nb")
    expectEqual(r.count, 1, "one code block region")
    expectEqual(r.first?.language, "card", "language parsed from fence")
    expectEqual(r.first?.body, 10..<15, "body is the inner line 'hello'")
    expect(r.first!.full.lowerBound == 2, "full starts at opening fence")

    let none = CodeBlockParser.regions(in: "no fences here")
    expectEqual(none.count, 0, "no regions without fences")
}

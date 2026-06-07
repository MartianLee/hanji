import MarkdownCore

func titleExtractorChecks() {
    expectEqual(TitleExtractor.title(fromMarkdown: "# Title\nx", fallback: "f"), "Title", "first H1")
    expectEqual(TitleExtractor.title(fromMarkdown: "no heading", fallback: "f"), "f", "fallback when no H1")
    expectEqual(TitleExtractor.title(fromMarkdown: "#NoSpace", fallback: "f"), "f", "# without space is not H1")
    expectEqual(TitleExtractor.title(fromMarkdown: "## H2", fallback: "f"), "f", "H2 is not H1")
}

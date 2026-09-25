import Foundation
import MarkdownCore

/// Wall-clock seconds for `body`, best of `runs` (the minimum filters out a
/// scheduler hiccup on a busy CI runner).
private func seconds(runs: Int = 3, _ body: () -> Void) -> Double {
    var best = Double.infinity
    for _ in 0..<runs {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9)
    }
    return best
}

/// Doubling the input must cost ≈2× the time, not the 4× a quadratic scan
/// costs. The absolute slack keeps sub-10ms runs from failing on noise.
private func expectLinear(_ name: String, _ input: (Int) -> String, n: Int,
                          _ parse: (String) -> Void) {
    let small = input(n), large = input(2 * n)
    let t1 = seconds { parse(small) }
    let t2 = seconds { parse(large) }
    expect(t2 <= 3 * t1 + 0.02, "\(name): 2× input took \(t2)s vs \(t1)s — superlinear")
}

/// A crafted note must not freeze the main thread: every parser here runs on a
/// click or a keystroke. Each case is an input that used to take seconds (an
/// opener per character, each rescanning the rest of the line). The bound is
/// generous for a debug build; the scaling check is what catches a quadratic.
func parserPerfChecks() {
    let bound = 0.5
    func repeated(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }

    // LinkParser: 20k unclosed `[[` on one line (runs on every editor click).
    let wikiOpeners = repeated("[[", 20_000)
    var links: [LinkRef] = []
    var t = seconds(runs: 1) { links = LinkParser.links(in: wikiOpeners) }
    expect(t < bound, "LinkParser 20k '[[' took \(t)s")
    expect(links.isEmpty, "unclosed '[[' are not links")
    let wikiTail = wikiOpeners + "[[Target]]"
    links = LinkParser.links(in: wikiTail)
    expectEqual(links.map(\.target), ["Target"], "valid wikilink after 20k openers")
    expectEqual(links.first?.range, 40_000..<40_010, "range covers only the closed '[[Target]]'")

    // Markdown-link half: every `[` looks for its `]`, then `(dest)`.
    let mdOpeners = repeated("[", 20_000)
    t = seconds(runs: 1) { links = LinkParser.links(in: mdOpeners) }
    expect(t < bound, "LinkParser 20k '[' took \(t)s")
    expect(links.isEmpty, "unclosed '[' are not links")
    links = LinkParser.links(in: mdOpeners + "x](Note.md)")
    expectEqual(links.map(\.target), ["Note.md"], "markdown link after 20k '['")
    expectEqual(links.first?.range, 0..<20_011, "link text may hold '[' — the match starts at the first")
    let openDests = repeated("[](", 10_000)
    t = seconds(runs: 1) { links = LinkParser.links(in: openDests) }
    expect(t < bound, "LinkParser 10k '[](' took \(t)s")
    expect(links.isEmpty, "unclosed '(' is not a link")

    // Many fences × many links: each match used to test every fence.
    let fencesAndLinks = repeated("```\n```\n", 5_000) + repeated("[[a]] ", 20_000)
    t = seconds(runs: 1) { links = LinkParser.links(in: fencesAndLinks) }
    expect(t < bound, "LinkParser 5k fences + 20k links took \(t)s")
    expectEqual(links.count, 20_000, "links after closed fences all count")

    expectLinear("LinkParser '[['", { repeated("[[", $0) }, n: 20_000) { _ = LinkParser.links(in: $0) }
    expectLinear("LinkParser '['", { repeated("[", $0) }, n: 20_000) { _ = LinkParser.links(in: $0) }

    // InlineTokenizer: same line (runs on every restyle, i.e. every keystroke).
    var spans: [MarkSpan] = []
    t = seconds(runs: 1) { spans = InlineTokenizer.spans(in: wikiOpeners) }
    expect(t < bound, "InlineTokenizer 20k '[[' took \(t)s")
    expect(spans.isEmpty, "unclosed '[[' tokenize to nothing")
    spans = InlineTokenizer.spans(in: wikiTail)
    expectEqual(spans.count, 1, "one link once a ']]' closes the line")
    expectEqual(spans.first?.markers, [0..<2, 40_008..<40_010], "the first '[[' pairs with the only ']]'")

    t = seconds(runs: 1) { spans = InlineTokenizer.spans(in: mdOpeners) }
    expect(t < bound, "InlineTokenizer 20k '[' took \(t)s")
    expect(spans.isEmpty, "unclosed '[' tokenize to nothing")
    let openParens = repeated("[a](", 10_000)
    t = seconds(runs: 1) { spans = InlineTokenizer.spans(in: openParens) }
    expect(t < bound, "InlineTokenizer 10k '[a](' took \(t)s")
    expect(spans.isEmpty, "unclosed '(' tokenize to nothing")
    let lateBar = repeated("[[", 10_000) + "|]]"
    t = seconds(runs: 1) { spans = InlineTokenizer.spans(in: lateBar) }
    expect(t < bound, "InlineTokenizer 10k '[[' + '|]]' took \(t)s")
    expect(spans.isEmpty, "an alias with no text is not a link")

    expectLinear("InlineTokenizer '[['", { repeated("[[", $0) }, n: 20_000) { _ = InlineTokenizer.spans(in: $0) }
    expectLinear("InlineTokenizer '['", { repeated("[", $0) }, n: 20_000) { _ = InlineTokenizer.spans(in: $0) }

    // DataviewQuery: the shape regex backtracked over trailing whitespace.
    let spaces = repeated(" ", 16_000)
    var parsed: DataviewQuery.Parsed?
    t = seconds(runs: 1) { parsed = DataviewQuery.parse("TABLE" + spaces) }
    expect(t < bound, "DataviewQuery TABLE + 16k spaces took \(t)s")
    expectEqual(parsed?.columns, [], "blank TABLE has no columns")
    t = seconds(runs: 1) { parsed = DataviewQuery.parse("TABLE" + spaces + "x" + spaces) }
    expect(t < bound, "DataviewQuery TABLE + spaces + column took \(t)s")
    expectEqual(parsed?.columns, ["x"], "column survives the padding")
    t = seconds(runs: 1) { parsed = DataviewQuery.parse("TABLE x" + spaces + "FROM #tag  \n ") }
    expect(t < bound, "DataviewQuery padded FROM took \(t)s")
    expectEqual(parsed?.source, .tag("tag"), "FROM after the padding still parses")

    expectLinear("DataviewQuery spaces", { "TABLE" + repeated(" ", $0) + "x" }, n: 16_000) { _ = DataviewQuery.parse($0) }

    // Tags: dedup by scanning the tags found so far was quadratic in distinct tags.
    func distinctTags(_ n: Int) -> String { (0..<n).map { "#t\($0)" }.joined(separator: " ") }
    let manyTags = distinctTags(20_000)
    var tags: [String] = []
    t = seconds(runs: 1) { tags = Tags.extract(from: manyTags) }
    expect(t < bound, "Tags 20k distinct took \(t)s")
    expectEqual(tags.count, 20_000, "every distinct tag kept")
    expectEqual(Tags.extract(from: manyTags + " #t0 #t19999 #new"), (0..<20_000).map { "t\($0)" } + ["new"],
                "repeats dropped, first-seen order kept")
    expectLinear("Tags distinct", distinctTags, n: 20_000) { _ = Tags.extract(from: $0) }
}

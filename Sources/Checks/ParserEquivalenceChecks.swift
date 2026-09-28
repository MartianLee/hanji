import Foundation
import MarkdownCore

/// The block parsers the widget pass runs on every keystroke (rules, images,
/// tables) skip most lines by their first character instead of building a
/// string for each. That must not change what they find: on random documents
/// they agree exactly with frozen copies of the plain versions
/// (LegacyParsers.swift), and TableParser given the tokenizer's code ranges
/// agrees with finding them itself.
func parserEquivalenceChecks() {
    var seed: UInt64 = 0x9A55E
    func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
    let vocabulary = ["---", "***", "___", " ---", "   ***", "    ---", "- - -", "--", "----- ", "```", "~~~", "```swift",
                      "    ```swift", "\t```", "- item", "1. x", "  continued", "![[img.png]]", "  ![alt](a.png)  ",
                      "![[a|b]]", "![](x)", "!not", "| a | b |", "|---|:--:|", "| 1 | 2 |", "a | b", "---|---",
                      "|:-|-:|", "\\| esc | x |", "", " ", "text", "> quote", "# head", "`code`", "tab\t---", "title: x",
                      "\u{00A0}---", "\u{3000}![[x.png]]", "\u{00A0}| a | b |", "---\u{0C}", "a\rb", "한글 | 표 |"]
    var failure: String?
    for round in 0..<3000 where failure == nil {
        var lines: [String] = []
        if next(4) == 0 { lines += ["---", "title: x", next(2) == 0 ? "---" : "tags: [a]"] }
        for _ in 0..<(5 + next(40)) { lines.append(vocabulary[next(vocabulary.count)]) }
        let text = lines.joined(separator: next(5) == 0 ? "\r\n" : "\n")
        if HRParser.lines(in: text) != LegacyHRParser.lines(in: text) { failure = "rules, round \(round): \(text.debugDescription)" }
        else if ImageParser.images(in: text) != LegacyImageParser.images(in: text) { failure = "images, round \(round): \(text.debugDescription)" }
        else if TableParser.tables(in: text) != LegacyTableParser.tables(in: text) { failure = "tables, round \(round): \(text.debugDescription)" }
        else if TableParser.tables(in: text, codeRanges: CodeBlockParser.codeRanges(in: text)) != LegacyTableParser.tables(in: text) {
            failure = "tables with given code ranges, round \(round): \(text.debugDescription)"
        }
    }
    expect(failure == nil, "the fast block parsers agree with the plain ones on 3,000 random notes (\(failure ?? "all agree"))")
}

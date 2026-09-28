import Foundation
import MarkdownCore

/// A fenced code block inside a list item, as CommonMark reads it: the fence
/// may sit deeper than 3 spaces there (its indent counts from the item's text),
/// so the GitHub READMEs that nest `    ```swift` under `- ` render as code.
/// Everywhere else the old rule holds: 4 spaces make an indented line, not a
/// fence, and a top-level block isn't closed by an indented fence.
func nestedFenceChecks() {
    func regions(_ s: String) -> [CodeBlockRegion] { CodeBlockParser.regions(in: s) }
    func codeLines(_ s: String) -> [String] {
        let ns = s as NSString
        return InlineTokenizer.spans(in: s).filter { $0.style == .codeBlock }
            .map { ns.substring(with: NSRange(location: $0.line.lowerBound, length: $0.line.count)) }
    }

    let readme = "- `all()`: all rows.\n\n    ```swift\n    // SELECT * FROM player\n    Player.all()\n    ```\n\n    By default, all columns.\n\n- `select(...)` picks columns."
    let r = regions(readme)
    expectEqual(r.count, 1, "a fence indented under a list item is a code block")
    expectEqual(r.first?.language, "swift", "with its language")
    expectEqual(r.first?.indent, 4, "and the fence's indent")
    expectEqual(codeLines(readme), ["    ```swift", "    // SELECT * FROM player", "    Player.all()", "    ```"],
                "the tokenizer styles exactly those lines as code")
    let ns = readme as NSString
    expectEqual(r.first?.bodyText(in: ns), "// SELECT * FROM player\nPlayer.all()",
                "the body a renderer gets drops the fence's indent")
    expect(HRParser.lines(in: "- a\n    ```\n    ---\n    ```").isEmpty, "a rule-like line inside it is code")

    expectEqual(regions("- a\n\t```\n\tx\n\t```").count, 1, "tab-indented under an item too")
    expectEqual(regions("- a\n\n\n    ```\n    x\n    ```").count, 1, "blank lines between keep the list going")
    expectEqual(regions("- a\n  more of a\n    ```\n    x\n    ```").count, 1, "so does an indented continuation line")
    expectEqual(regions("1. one\n    ```\n    x\n    ```").count, 1, "ordered items count")
    expectEqual(regions("- [ ] task\n    ```\n    x\n    ```").count, 1, "task items count")
    expectEqual(regions("- a\n    ```\n    x\n```").count, 1, "a less indented bare fence closes it")
    expectEqual(regions("- a\n        ```\n        x\n        ```").count, 1, "deeper nesting too")

    // Unchanged: no list, no fence.
    expect(regions("Para\n\n    ```swift\n    x\n    ```").isEmpty, "outside a list, 4 spaces is not a fence")
    expect(codeLines("Para\n\n    ```swift\n    x\n    ```").isEmpty, "and nothing is styled as code")
    expect(regions("- a\n\nPara\n\n    ```\n    x\n    ```").isEmpty, "a paragraph at the margin ends the list")
    let top = "```\na\n    ```\nb\n```"
    expectEqual(regions(top).map(\.full), [0..<(top as NSString).length], "an indented fence doesn't close a top-level block")
    expectEqual(regions("- a\n```\nx\n    ```\ny\n```").map(\.indent), [0], "nor one opened at the margin under a list")
    expectEqual(regions("```js\nx\n```").first?.indent, 0, "a top-level block has no indent")
    expectEqual(regions("```js\n  x\n```").first?.bodyText(in: "```js\n  x\n```"), "  x",
                "and its body keeps its own indentation")
    expectEqual(CodeBlockParser.codeRanges(in: "- a\n    ```\n    open").count, 1, "an unclosed nested fence is code to the end, as at the top")

    // The fast list-item test agrees with the editor's list grammar.
    var seed: UInt64 = 0x11575
    let alphabet = [" ", "\t", "-", "*", "+", "1", "9", ".", ")", "x", "[", "]", "a", "\r", "0"]
    var disagree: String?
    for _ in 0..<20_000 where disagree == nil {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        var line = ""
        for k in 0..<Int((seed >> 60) % 12) { line += alphabet[Int((seed >> UInt64(k * 4 % 56)) % UInt64(alphabet.count))] }
        if ListContext.isItem(line) != ListIndent.isListItem(line) { disagree = line }
    }
    for line in ["1234567890. x", "123456789. x", "- ", "-", "-x", "10) y", "  * [ ] t"] where disagree == nil {
        if ListContext.isItem(line) != ListIndent.isListItem(line) { disagree = line }
    }
    expect(disagree == nil, "ListContext.isItem matches ListIndent.isListItem (\(disagree.map { $0.debugDescription } ?? "all agree"))")
}

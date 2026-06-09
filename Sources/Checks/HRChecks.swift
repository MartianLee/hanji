import Foundation
import MarkdownCore

func hrParserChecks() {
    let text = """
    ---
    title: front
    ---
    Body
    ---
    ***
    ___
    --
    ```
    ---
    ```
     ---\u{0020}
    """
    let lines = HRParser.lines(in: text)
    let ns = text as NSString
    let matched = lines.map { ns.substring(with: NSRange(location: $0.lowerBound, length: $0.upperBound - $0.lowerBound)).trimmingCharacters(in: .whitespaces) }
    expectEqual(matched.count, 4, "exactly the four real rules match")
    expect(matched.allSatisfy { ["---", "***", "___"].contains($0) }, "matches are rule lines")

    // Leading frontmatter delimiters and fenced-code contents are not rules; "--" is too short.
    let offsets = lines.map(\.lowerBound)
    expect(!offsets.contains(0), "frontmatter open is not an HR")
    expectEqual(HRParser.lines(in: "no rules here").count, 0, "no false positives")
    expectEqual(HRParser.lines(in: "---").count, 1, "a lone --- at doc start without closing frontmatter is an HR")
}

import Foundation
import MarkdownCore

func listContinuationChecks() {
    func act(_ line: String) -> ListContinuation.Action { ListContinuation.action(for: line) }

    // Bullets carry their own marker character and indent forward.
    expectEqual(act("- item"), .continue("- "), "dash bullet continues")
    expectEqual(act("* item"), .continue("* "), "star bullet keeps its character")
    expectEqual(act("+ item"), .continue("+ "), "plus bullet keeps its character")
    expectEqual(act("    - deep"), .continue("    - "), "indent is carried to the next item")

    // Tasks continue as a fresh, unchecked task.
    expectEqual(act("- [ ] todo"), .continue("- [ ] "), "open task continues unchecked")
    expectEqual(act("- [x] done"), .continue("- [ ] "), "done task continues unchecked, not done")

    // Numbers increment.
    expectEqual(act("1. first"), .continue("2. "), "1. → 2.")
    expectEqual(act("9. ninth"), .continue("10. "), "9. → 10. (digit carry)")
    expectEqual(act("3) third"), .continue("4) "), "the ')' delimiter is preserved")
    expectEqual(act("  2. nested"), .continue("  3. "), "indented numbering increments")

    // An empty item ends the list instead of adding another one.
    expectEqual(act("- "), .end(markerLength: 2), "empty bullet ends the list")
    expectEqual(act("  - "), .end(markerLength: 4), "empty indented bullet ends, indent included")
    expectEqual(act("- [ ] "), .end(markerLength: 6), "empty task ends the list")
    expectEqual(act("7. "), .end(markerLength: 3), "empty numbered item ends the list")

    // Everything else is a plain Return.
    expectEqual(act("plain text"), .none, "plain line")
    expectEqual(act(""), .none, "empty line")
    expectEqual(act("# Heading"), .none, "heading")
    expectEqual(act("1.no space"), .none, "digit-dot without a space")
}

func listIndentChecks() {
    // "is this a list line at all" is what decides whether Tab/Shift-Tab belong to
    // the list at all, so it is worth naming rather than inferring from indent().
    expect(ListIndent.isListItem("- item"), "bullet is a list item")
    expect(ListIndent.isListItem("1. item"), "numbered line is a list item")
    expect(ListIndent.isListItem("- [x] done"), "task is a list item")
    expect(ListIndent.isListItem("\t- nested"), "nested bullet is a list item")
    expect(ListIndent.isListItem("- "), "an empty item still counts")
    expect(!ListIndent.isListItem("plain text"), "prose is not a list item")
    expect(!ListIndent.isListItem(""), "an empty line is not a list item")

    // Tab nests the item, whatever kind of list it is — including the empty item
    // Return just created, which is exactly where you reach for Tab.
    expectEqual(ListIndent.indent(for: "- item"), "\t", "bullet indents")
    expectEqual(ListIndent.indent(for: "1. item"), "\t", "numbered item indents")
    expectEqual(ListIndent.indent(for: "- [ ] todo"), "\t", "task indents")
    expectEqual(ListIndent.indent(for: "- "), "\t", "the empty item Return leaves behind indents")
    expectEqual(ListIndent.indent(for: "\t- deep"), "\t", "an already nested item indents further")
    expectEqual(ListIndent.indent(for: "plain text"), nil, "plain line gets a plain Tab")
    expectEqual(ListIndent.indent(for: ""), nil, "empty line gets a plain Tab")

    // Shift-Tab removes exactly one level, tabs or spaces.
    expectEqual(ListIndent.outdent(for: "\t- item"), 1, "one tab is one level")
    expectEqual(ListIndent.outdent(for: "\t\t- item"), 1, "only the outermost level goes")
    expectEqual(ListIndent.outdent(for: "    - item"), 4, "four spaces are one level")
    expectEqual(ListIndent.outdent(for: "  - item"), 2, "a short space indent goes entirely")
    expectEqual(ListIndent.outdent(for: "      - item"), 4, "six spaces drop one level, not all")
    expectEqual(ListIndent.outdent(for: "- item"), nil, "a top-level item has nothing to outdent")
    expectEqual(ListIndent.outdent(for: "\tplain"), nil, "indented plain text is not a list")
}

func listRenumberChecks() {
    /// Renumber around the line holding `marker` (the first occurrence of it).
    func renumber(_ text: String, at marker: String, moved: Bool = false,
                  code: [Range<Int>] = []) -> String {
        let ns = text as NSString
        let offset = ns.range(of: marker).location
        let edits = ListRenumber.edits(in: text, around: offset, moved: moved ? offset : nil,
                                       isCode: { o in code.contains { $0.contains(o) } })
        let out = NSMutableString(string: text)
        for e in edits.reversed() { out.replaceCharacters(in: e.range, with: e.number) }
        return out as String
    }

    // Tab: a nested item starts its own count; the outer list closes ranks.
    expectEqual(renumber("9. a\n\t10. quest\n10. font\n11. hp", at: "quest", moved: true),
                "9. a\n\t1. quest\n10. font\n11. hp", "an item nested under 9. becomes 1.")
    expectEqual(renumber("1. a\n\t2. b\n3. c", at: "b", moved: true),
                "1. a\n\t1. b\n2. c", "the items after it move up a number")
    expectEqual(renumber("1. a\n\t1. x\n\t7. b", at: "b", moved: true),
                "1. a\n\t1. x\n\t2. b", "nesting under an existing sublist continues it")
    // Shift-Tab: back in the outer list, at its place in the count.
    expectEqual(renumber("1. a\n1. b\n2. c", at: "b", moved: true),
                "1. a\n2. b\n3. c", "an outdented item takes the next outer number")
    // Return after an item copied from elsewhere: the count follows the list, not the copy.
    expectEqual(renumber("1. a\n2. b\n3. c\n2. q\n3. ", at: "q"),
                "1. a\n2. b\n3. c\n4. q\n5. ", "a pasted 2. is renumbered in place")

    expectEqual(renumber("5. a\n7. b", at: "b"), "5. a\n6. b", "a list keeps the number it starts at")
    expectEqual(renumber("1. a\n2. b", at: "b"), "1. a\n2. b", "a list in order is left alone")
    expectEqual(ListRenumber.edits(in: "1. a\n2. b", around: 6), [], "and no edits are made")
    expectEqual(renumber("1. a\n\n5. b", at: "b"), "1. a\n\n5. b", "a blank line ends the list")
    expectEqual(renumber("1. a\n\t- x\n\t- y\n3. b", at: "b"), "1. a\n\t- x\n\t- y\n2. b",
                "a nested bullet list doesn't break the count")
    expectEqual(renumber("1. a\n   more\n3. b", at: "b"), "1. a\n   more\n2. b",
                "nor does an item's continuation line")
    expectEqual(renumber("1. a\n- x\n4. b", at: "b"), "1. a\n- x\n4. b", "a bullet at the same level starts a new list")
    expectEqual(renumber("1. a\n1) b", at: "b"), "1. a\n1) b", "so does a different delimiter")
    expectEqual(renumber("1. a\n\t```\n\t5. code\n\t```\n3. b", at: "b", code: [5..<24]),
                "1. a\n\t```\n\t5. code\n\t```\n2. b", "numbers inside code are code")
    expectEqual(renumber("8. a\n9. b\n13. c", at: "a"), "8. a\n9. b\n10. c", "renumbering reaches below the line too")
    expectEqual(renumber("    1. a\n    5. b", at: "b"), "    1. a\n    2. b", "spaces nest like tabs")
}

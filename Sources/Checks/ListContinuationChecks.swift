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

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

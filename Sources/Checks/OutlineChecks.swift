import AppCore
import Combine
import Foundation
import MarkdownCore

/// The outline lists the headings the editor styles as headings — none from
/// fenced code or frontmatter — with their visible text.
func outlineChecks() {
    let note = """
    ---
    title: x
    ---
    # Top
    intro #tag
    ## **Bold** and [[Target|Alias]] and `code` ##
    ```md
    # not a heading
    ```
    #nospace
    ### Third
    """
    let h = Outline.headings(in: note)
    expectEqual(h.map(\.level), [1, 2, 3], "levels, in order; none from frontmatter, code or #tag")
    expectEqual(h.map(\.title), ["Top", "Bold and Alias and code", "Third"],
                "titles keep the visible text and drop a closing ## run")
    let ns = note as NSString
    expectEqual(h.map(\.offset), [ns.range(of: "# Top").location, ns.range(of: "## **Bold**").location,
                                  ns.range(of: "### Third").location], "offsets are the heading lines' starts")

    expect(Outline.headings(in: "```\n# inside an unclosed fence").isEmpty, "an unclosed fence holds no headings")
    expect(Outline.headings(in: "plain text\n").isEmpty, "a note without headings has none")

    expectEqual(Outline.current(in: h, at: 0), nil, "before the first heading: none current")
    expectEqual(Outline.current(in: h, at: h[1].offset), 1, "on a heading line: that heading")
    expectEqual(Outline.current(in: h, at: h[1].offset + 3), 1, "inside its section: still that heading")
    expectEqual(Outline.current(in: h, at: ns.length), 2, "at the end: the last heading")

    // Recomputed (throttled) while typing, so a long note must stay cheap.
    let long = (0..<1000).map { "## Section \($0)\nSome **bold** text and a [[link]].\n- item\n\n" }.joined()
    let t0 = Date()
    let many = Outline.headings(in: long)
    let elapsed = Date().timeIntervalSince(t0)
    expectEqual(many.count, 1000, "every heading of a 4,000-line note")
    expect(elapsed < 0.25 * Check.timeSlack, "a 4,000-line note's outline in \(elapsed)s")
}

/// The outline's current heading follows the caret while editing and the top
/// visible line while reading; a click's jump asks for the line at the top,
/// and only that jump does.
func outlineFocusChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-outline-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    for name in ["A.md", "B.md"] {
        try? "# \(name)\ntext\n## Two\nmore\n".write(to: vault.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let suite = "mk-outline-\(UUID().uuidString)"
    let s = AppState(defaults: UserDefaults(suiteName: suite)!)
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    s.openVault(at: vault)
    s.openNote(relativePath: "A.md", newTab: true)

    var seen: [Int] = []
    let token = s.focusOffset.sink { seen.append($0) }
    defer { token.cancel() }

    s.caretMoved(to: 12)
    expectEqual(seen.last, 12, "editing: the caret")
    s.viewportMoved(top: 30)
    expectEqual(seen.last, 12, "editing: scrolling doesn't move it")
    s.toggleReading(s.activeTabID!)
    expectEqual(seen.last, 30, "reading: the top visible line")
    s.caretMoved(to: 5)
    expectEqual(seen.last, 30, "reading: a caret move doesn't move it")
    s.toggleReading(s.activeTabID!)
    expectEqual(seen.last, 5, "editing again: the caret")

    s.openNote(relativePath: "B.md", newTab: true)
    expectEqual(seen.last, 0, "another tab starts at its top")

    s.reveal(offset: 9)
    expectEqual(s.pendingCursorOffset, 9, "reveal jumps the editor")
    expect(s.pendingJumpToTop, "with the line at the top")
    s.pendingCursorOffset = nil                 // the editor applied the jump
    expect(!s.pendingJumpToTop, "the placement goes with the jump")
    s.pendingCursorOffset = 3                   // a search result's jump
    expect(!s.pendingJumpToTop, "other jumps keep their placement")
}

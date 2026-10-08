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

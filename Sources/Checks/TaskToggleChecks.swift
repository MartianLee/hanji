import MarkdownCore

func taskToggleChecks() {
    let open = TaskToggle.toggle(in: "- [ ] todo", at: 3)
    expectEqual(open?.offset, 3, "toggles state char")
    expectEqual(open?.replacement, "x", "open -> x")

    let done = TaskToggle.toggle(in: "- [x] todo", at: 2)
    expectEqual(done?.replacement, " ", "done -> space (click on '[')")

    expect(TaskToggle.toggle(in: "- [ ] todo", at: 8) == nil, "click on text is not a toggle")
    expect(TaskToggle.toggle(in: "plain line", at: 1) == nil, "non-task is nil")

    let second = TaskToggle.toggle(in: "x\n- [ ] a", at: 5)   // offset 5 -> '[' of line 2
    expectEqual(second?.offset, 5, "line-2 checkbox offset")

    // Nested tasks render a checkbox too (after the indent), so they must toggle.
    let nested = TaskToggle.toggle(in: "- [ ] parent\n    - [ ] child", at: 19)   // '[' of the child
    expectEqual(nested?.offset, 20, "an indented task toggles its own state char")
    expectEqual(nested?.replacement, "x", "indented open -> x")
    let tabbed = TaskToggle.toggle(in: "\t- [x] child", at: 3)
    expectEqual(tabbed?.offset, 4, "a tab-indented task toggles")
    expect(TaskToggle.toggle(in: "    - [ ] child", at: 1) == nil, "a click in the indent is not a toggle")
}

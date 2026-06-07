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
}

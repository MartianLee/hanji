import AppKit
import EditorEngine

private let positionNote = (0..<200).map { "## Heading \($0)\ntext under \($0)\n" }.joined()
private func line(_ n: Int) -> Int { (positionNote as NSString).range(of: "## Heading \(n)\n").location }

/// A jump can name the line that goes to the top, apart from the caret: a tab
/// shown again comes back with its caret where it was and the line that was at
/// the top back at the top.
func editorJumpTopLineChecks() {
    guard let h = EditorHarness(positionNote) else { expect(false, "editor found"); return }
    defer { h.close() }
    h.pump(0.4)
    h.jumpTopLine = line(120)
    h.jump(to: line(125) + 4)
    h.pump(0.3)
    expectEqual(h.textView.selectedRange().location, line(125) + 4, "the caret lands where asked")
    expectEqual(h.topLineOffset, line(120), "and the named line is at the top")
}

/// An editor made for a note that was left somewhere starts there — also an
/// inactive pane's, which jumps don't reach — without taking the keyboard,
/// and reports its top line as it scrolls, so its tab can remember it.
func editorStartPositionChecks() {
    guard let h = EditorHarness(positionNote, isLive: false, startCaret: line(82) + 2, startTopLine: line(80))
    else { expect(false, "editor found"); return }
    defer { h.close() }
    h.pump(0.4)
    expectEqual(h.topLineOffset, line(80), "the editor starts with the remembered line at the top")
    expectEqual(h.textView.selectedRange().location, line(82) + 2, "and the caret where it was")
    expect(h.window.firstResponder !== h.textView, "without taking the keyboard")

    h.viewportTops = []
    h.scrollToTop(of: line(150))
    h.pump(0.2)
    expectEqual(h.viewportTops.last, line(150), "an inactive pane reports its top line too")

    // Only once: later updates leave the view to the reader.
    h.startTopLine = line(10)
    h.rebuild()
    expectEqual(h.topLineOffset, line(150), "a later update doesn't send it back to its start")
}

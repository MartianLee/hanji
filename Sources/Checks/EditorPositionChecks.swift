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

/// A note of long paragraphs, each wrapping over several lines.
func proseNote(_ name: String) -> String {
    let sentence = "\(name) 문단의 긴 문장은 여러 줄로 감싸여 보이도록 충분히 길게 씁니다. "
    return (0..<40).map { i in "## \(name) 섹션 \(i)\n\n" + String(repeating: sentence, count: 6) + "\n\n- 항목 \(i)\n\n" }.joined()
}

/// The top the editor reports is exact — the wrapped line at the top edge,
/// even inside a long paragraph, and how far into it the view is — so a jump
/// or a new editor handed it back shows the very same view. (It used to say
/// only which paragraph was at the top, and coming back put that paragraph's
/// start there: the view moved up by up to a paragraph.)
func editorTopRoundTripChecks() {
    let note = proseNote("왼쪽")
    guard let h = EditorHarness(note, width: 600) else { expect(false, "editor found"); return }
    defer { h.close() }
    h.pump(0.4)
    let tv = h.textView
    guard let tlm = tv.textLayoutManager, let tcs = tlm.textContentManager else { expect(false, "layout"); return }
    // Lay the note out for real (and the view as tall), so the targets below
    // are where their lines will stay.
    func layOut() {
        tlm.ensureLayout(for: tlm.documentRange)
        let height = tlm.usageBoundsForTextContainer.maxY + tv.textContainerInset.height * 2
        if tv.frame.height < height { tv.setFrameSize(NSSize(width: tv.frame.width, height: height)) }
    }
    /// 7 points into the `line`th wrapped line of section `section`'s paragraph.
    func target(section: Int, line: Int) -> CGFloat? {
        layOut()
        let start = (note as NSString).range(of: "## 왼쪽 섹션 \(section)\n\n").upperBound
        guard let loc = tcs.location(tcs.documentRange.location, offsetBy: start),
              let frag = tlm.textLayoutFragment(for: loc), frag.textLineFragments.count > line else { return nil }
        return frag.layoutFragmentFrame.minY + frag.textLineFragments[line].typographicBounds.minY + 7 + tv.textContainerOrigin.y
    }
    var last: (top: Int, delta: CGFloat)?
    for (section, line) in [(8, 2), (12, 3), (20, 1), (25, 0)] {
        guard let y = target(section: section, line: line) else { expect(false, "setup: section \(section) wraps"); continue }
        h.viewportTops = []; h.viewportDeltas = []
        tv.scroll(NSPoint(x: 0, y: y))
        h.pump(0.2)
        let y0 = tv.visibleRect.minY
        guard let top = h.viewportTops.last, let delta = h.viewportDeltas.last else { expect(false, "a report at \(y)"); continue }
        if line > 0 {
            expect(top > 0 && (note as NSString).character(at: top - 1) != 0x0A,
                   "the reported top is the wrapped line, inside its paragraph (section \(section))")
        }
        h.scrollToTop(of: 0)
        h.jumpTopLine = top; h.jumpTopDelta = delta
        h.jump(to: top)
        h.pump(0.3)
        expectEqual(tv.visibleRect.minY, y0, "a jump to the reported top shows the same view (section \(section), line \(line))")
        last = (top, delta)
    }
    guard let last else { return }
    let laidOutY = tv.visibleRect.minY
    guard let fresh = EditorHarness(note, width: 600, isLive: false, startCaret: last.top,
                                    startTopLine: last.top, startTopDelta: last.delta) else { return }
    defer { fresh.close() }
    fresh.pump(0.4)
    // Both laid out for real at the same width: the same view is the same y.
    expectEqual(fresh.textView.visibleRect.minY, laidOutY, "a new editor started at it shows the same view")
}

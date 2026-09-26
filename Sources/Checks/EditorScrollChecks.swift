import AppKit
import SwiftUI
import EditorEngine

/// Return near the bottom of a long note must not move the viewport: the caret
/// stays where the user is typing. Restyling used to rewrite attributes over the
/// whole document, which threw TextKit 2 back onto estimated line heights, so
/// the post-edit scroll went to the caret's *estimated* place and the real
/// layout then landed it thousands of points below the viewport.
func editorScrollChecks() {
    var lines: [String] = []
    for i in 0..<150 {
        lines += ["## Section \(i)", "Paragraph \(i) with **bold**, `code` and a [[link]].", "- item \(i)", ""]
    }
    var text = lines.joined(separator: "\n")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: MarkdownEditorView(text: Binding(get: { text }, set: { text = $0 })))
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    pump(0.5)
    func find(_ v: NSView) -> NSTextView? { (v as? NSTextView) ?? v.subviews.lazy.compactMap(find).first }
    guard let tv = find(window.contentView!), let clip = tv.enclosingScrollView?.contentView,
          let tlm = tv.textLayoutManager else { expect(false, "editor text view found"); return }
    window.makeFirstResponder(tv)

    func caretY() -> CGFloat {
        guard let start = tlm.location(tlm.documentRange.location, offsetBy: tv.selectedRange().location) else { return -1 }
        var y: CGFloat = -1
        tlm.enumerateTextSegments(in: NSTextRange(location: start), type: .selection, options: []) { _, f, _, _ in
            y = f.minY; return false
        }
        return y
    }
    func pressReturn() {
        window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: "\r",
                                          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        pump(0.3)   // let the deferred widget/layout pass run
    }

    // Caret at the end of a paragraph three-quarters down, in view, laid out.
    let ns = tv.string as NSString
    let line = ns.lineRange(for: NSRange(location: ns.range(of: "Paragraph 110 with").location, length: 0))
    tv.setSelectedRange(NSRange(location: line.location + line.length - 1, length: 0))
    pump(0.3)
    tv.scrollRangeToVisible(tv.selectedRange())
    pump(0.3)
    let before = clip.documentVisibleRect.minY
    let height = clip.documentVisibleRect.height
    expect((0...height).contains(caretY() - before), "setup: the caret is in view before typing")

    for n in 1...3 {
        pressReturn()
        let visible = clip.documentVisibleRect.minY
        let inView = caretY() - visible
        expect((0...height).contains(inView), "Return #\(n): the caret stays in view (was \(Int(inView))pt from the top)")
        expect(abs(visible - before) < 120, "Return #\(n): the viewport doesn't jump (moved \(Int(visible - before))pt)")
    }
}

/// Committing a restyle that changes nothing must not edit the storage at all
/// (any attribute write discards that range's layout); a real change touches
/// only its own run.
func styleCommitChecks() {
    final class Counter: NSObject, NSTextStorageDelegate {
        var edited: [NSRange] = []
        func textStorage(_ s: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                         range: NSRange, changeInLength: Int) { edited.append(range) }
    }
    let storage = NSTextStorage(string: "alpha beta gamma")
    storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 6, length: 4))
    let counter = Counter()
    storage.delegate = counter

    LivePreviewStyler.commit(NSTextStorage(attributedString: storage), to: storage)
    expectEqual(counter.edited.count, 0, "an unchanged restyle performs no edit")

    let styled = NSTextStorage(attributedString: storage)
    styled.addAttribute(.foregroundColor, value: NSColor.blue, range: NSRange(location: 11, length: 5))
    LivePreviewStyler.commit(styled, to: storage)
    expectEqual(counter.edited.count, 1, "a change is committed in one edit")
    expectEqual(counter.edited.first, NSRange(location: 11, length: 5), "covering only the changed run")
    expect((storage.attribute(.foregroundColor, at: 12, effectiveRange: nil) as? NSColor) == .blue, "with the new value")
}

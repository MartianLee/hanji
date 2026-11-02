import AppKit
import MarkdownCore
import EditorEngine

/// Numbered items' text starts at one place whatever the number — and where a
/// wrapped item's later lines start: a narrow number's `.` is spaced out by
/// what it leaves.
func orderedAlignChecks() {
    let text = "1. one\n4. four\n8. eight\n10. ten\n100. hundred\n\t2. nested\n7. "
    let storage = NSTextStorage(string: text)
    LivePreviewStyler.apply(Decorator.decorations(spans: InlineTokenizer.spans(in: text), selection: 0..<0), to: storage)
    let ns = text as NSString
    let font = LivePreviewStyler.baseFont
    func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
    /// Where the item's text starts, from the marker's start: the marker's width plus the delimiter's kern.
    func textStart(_ marker: String, line: String) -> CGFloat {
        let delimiter = ns.range(of: line).location + (marker as NSString).length - 2
        return width(marker) + ((storage.attribute(.kern, at: delimiter, effectiveRange: nil) as? CGFloat) ?? 0)
    }
    let target = textStart("1. ", line: "1. one")
    let wrapped = (storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? -1
    expect(abs(target - wrapped) < 1, "item text starts where its wrapped lines do (\(target) vs \(wrapped))")
    for (marker, line) in [("4. ", "4. four"), ("8. ", "8. eight"), ("10. ", "10. ten"), ("2. ", "2. nested"), ("7. ", "7. ")] {
        expect(abs(textStart(marker, line: line) - target) < 0.5, "\(line): text at the same place (\(textStart(marker, line: line)) vs \(target))")
    }
    expectEqual(storage.attribute(.kern, at: ns.range(of: "100. ").location + 3, effectiveRange: nil) as? CGFloat, nil,
                "a number wider than the column pushes its text on, unkerned")
    expectEqual(storage.attribute(.kern, at: ns.range(of: "1. one").location + 2, effectiveRange: nil) as? CGFloat, nil,
                "nor the space before the text, where the caret would float in the gap")
}

/// In the editor, the numbered items' text lines up on screen.
func editorOrderedAlignChecks() {
    let note = "1. one\n4. four\n8. eight\n10. ten\nplain"
    guard let h = EditorHarness(note, cursorOffset: (note as NSString).length) else { expect(false, "editor found"); return }
    defer { h.close() }
    h.pump(0.4)
    let tv = h.textView
    func x(_ word: String) -> CGFloat {
        let screen = tv.firstRect(forCharacterRange: NSRange(location: (tv.string as NSString).range(of: word).location, length: 1), actualRange: nil)
        return screen.minX
    }
    let one = x("one")
    for word in ["four", "eight", "ten"] {
        expect(abs(x(word) - one) < 0.75, "\(word) starts where one does (\(x(word)) vs \(one))")
    }
}

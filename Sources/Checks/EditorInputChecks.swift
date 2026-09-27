import AppKit
import SwiftUI
import EditorEngine
import MarkdownCore

/// A real editor in an offscreen window, driven by key events.
final class EditorHarness {
    var text: String
    var cursorOffset: Int?
    let window: NSWindow
    let textView: NSTextView

    init?(_ initial: String, cursorOffset initialOffset: Int? = nil) {
        text = initial
        cursorOffset = initialOffset
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
        var box: EditorHarness?
        let binding = Binding(get: { box?.text ?? initial }, set: { box?.text = $0 })
        let offset = Binding(get: { box?.cursorOffset ?? initialOffset }, set: { box?.cursorOffset = $0 })
        let host = NSHostingView(rootView: MarkdownEditorView(text: binding, cursorOffset: offset))
        hosting = host
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        func find(_ v: NSView) -> NSTextView? { (v as? NSTextView) ?? v.subviews.lazy.compactMap(find).first }
        guard let tv = find(window.contentView!) else { return nil }
        textView = tv
        box = self
        window.makeFirstResponder(tv)
    }

    func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func key(_ chars: String, _ code: UInt16) {
        window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: chars,
                                          charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
    }

    /// Type `s` one key at a time (Return for "\n").
    func type(_ s: String) {
        for ch in s {
            if ch == "\n" { key("\r", 36) } else { key(String(ch), 0) }
        }
        pump()
    }

    private var hosting: NSHostingView<MarkdownEditorView>?

    func caret(at offset: Int) { textView.setSelectedRange(NSRange(location: offset, length: 0)); pump() }

    /// Ask the editor to jump to `offset`, the way search results do.
    func jump(to offset: Int) {
        cursorOffset = offset
        hosting?.rootView = MarkdownEditorView(text: Binding(get: { self.text }, set: { self.text = $0 }),
                                               cursorOffset: Binding(get: { self.cursorOffset },
                                                                     set: { self.cursorOffset = $0 }))
        pump(0.4)
    }

    /// Is the caret inside the visible part of the document?
    var caretInView: (Bool, String) {
        guard let tlm = textView.textLayoutManager, let clip = textView.enclosingScrollView?.contentView,
              let start = tlm.location(tlm.documentRange.location, offsetBy: textView.selectedRange().location)
        else { return (false, "no layout") }
        var y: CGFloat = -1
        tlm.enumerateTextSegments(in: NSTextRange(location: start), type: .selection, options: []) { _, f, _, _ in
            y = f.minY; return false
        }
        let vis = clip.documentVisibleRect
        return (y >= vis.minY && y <= vis.maxY, "caret y=\(Int(y)), visible \(Int(vis.minY))–\(Int(vis.maxY))")
    }
    func close() { window.orderOut(nil) }
}

/// What you type is what's saved: no smart dashes or quotes. `---` is a rule or
/// frontmatter, `"` in code and YAML is a quote.
func editorPlainTypingChecks() {
    guard let h = EditorHarness("") else { expect(false, "editor found"); return }
    defer { h.close() }
    h.type("---\na -- b\nsay \"hi\" it's\n")
    expectEqual(h.text, "---\na -- b\nsay \"hi\" it's\n", "typed text is saved exactly, no smart dashes or quotes")
}

/// A fence you've opened but not yet closed is code — it's exactly what you're in
/// while typing a new block, and the styling already treats it that way.
func unclosedFenceChecks() {
    expectEqual(CodeBlockParser.codeRanges(in: "intro\n```yaml\n- a: 1"), [6..<20], "an unclosed fence runs to the end")
    expectEqual(CodeBlockParser.codeRanges(in: "```\nx\n```\nafter"), [0..<9], "a closed block is just the block")
    expectEqual(Tags.extract(from: "```\n#inside"), [], "no tags in an unclosed fence")

    guard let h = EditorHarness("```yaml\n- name: a") else { expect(false, "editor found"); return }
    defer { h.close() }
    h.caret(at: (h.text as NSString).length)
    h.type("\n")
    expectEqual(h.text, "```yaml\n- name: a\n", "Return in an unclosed fence doesn't continue a list")
    h.key("\t", 48); h.pump()
    expectEqual(h.text, "```yaml\n- name: a\n\t", "Tab there types a tab instead of nesting")
}

/// A link written inside inline code is code: not a link to follow, not a backlink.
func linkInCodeChecks() {
    expectEqual(LinkParser.links(in: "see `[[Beta]]` and [[Gamma]]").map(\.target), ["Gamma"],
                "a [[link]] in inline code isn't a link")
    expectEqual(LinkParser.links(in: "``a [x](y.md) b`` [ok](z.md)").map(\.target), ["z.md"],
                "nor is a markdown link in a double-backtick span")
    expectEqual(CodeBlockParser.allCodeRanges(in: "a `b` c\n```\nd\n```\ne ``f`` g"), [2..<5, 8..<17, 20..<25],
                "fences and inline spans, in order")
    // A crafted line of backtick runs, each a different length, stays linear.
    let crafted = (1...600).map { String(repeating: "`", count: $0) }.joined(separator: "a")
    let t0 = Date()
    _ = CodeBlockParser.allCodeRanges(in: crafted)
    expect(Date().timeIntervalSince(t0) < 0.1, "a 180k-char line of distinct backtick runs scans quickly")
}

/// Frontmatter needs its closing `---`; a lone `---` on line 1 is a rule, and
/// the rest of the note is ordinary markdown.
func unclosedFrontmatterChecks() {
    let spans = InlineTokenizer.spans(in: "---\n# Title\nSome **bold** text")
    expect(!spans.contains { $0.style == .frontmatter }, "no closing --- → no frontmatter")
    expect(spans.contains { $0.style == .heading(1) }, "the heading is a heading")
    expect(spans.contains { $0.style == .bold }, "bold is bold")
    let closed = InlineTokenizer.spans(in: "---\ntitle: x\n---\n# Title")
    expectEqual(closed.filter { $0.style == .frontmatter }.count, 3, "closed frontmatter still covers its three lines")
}

/// Composing Hangul must not be restyled mid-composition (the jamo jump and
/// flicker): the editor should edit the storage no more than a plain text view
/// does for the same composition.
func imeCompositionChecks() {
    func compose(in tv: NSTextView, pump: () -> Void) -> Int {
        var edits = 0
        let token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                           object: tv.textStorage, queue: nil) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        tv.setSelectedRange(NSRange(location: 6, length: 0)); pump()
        edits = 0
        for step in ["ㅎ", "하", "한", "한ㄱ", "한그", "한글"] {
            tv.setMarkedText(step, selectedRange: NSRange(location: (step as NSString).length, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
            pump()
        }
        return edits
    }
    guard let h = EditorHarness("first line\nsecond line") else { expect(false, "editor found"); return }
    defer { h.close() }
    let editor = compose(in: h.textView) { h.pump(0.05) }

    let plain = NSTextView(usingTextLayoutManager: true)
    plain.string = "first line\nsecond line"
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                     backing: .buffered, defer: false)
    w.contentView = plain; w.makeFirstResponder(plain)
    let baseline = compose(in: plain) { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    expectEqual(editor, baseline, "no restyle while composing (editor edits vs plain text view)")
}

/// After a paste or a jump to an offset (search results), the caret is on screen
/// once layout has settled — not left where its estimated position was.
func editorRevealChecks() {
    let long = (0..<800).map { "## Section \($0)\nSome text with **bold** and `code`.\n" }.joined()
    // Jump, the way a search result does.
    guard let jump = EditorHarness(long) else { expect(false, "editor found"); return }
    let target = (long as NSString).range(of: "## Section 790").location
    jump.jump(to: target)
    let (jumped, jumpInfo) = jump.caretInView
    expect(jumped, "a jump to an offset deep in a long note shows the caret (\(jumpInfo))")
    jump.close()

    // Paste many lines.
    guard let paste = EditorHarness("top\n\nbottom") else { expect(false, "editor found"); return }
    defer { paste.close() }
    paste.caret(at: 4)
    let block = (0..<200).map { "- pasted line \($0) with **bold**" }.joined(separator: "\n")
    paste.textView.insertText(block, replacementRange: paste.textView.selectedRange())
    paste.pump(0.4)
    let (pasted, pasteInfo) = paste.caretInView
    expect(pasted, "after pasting 200 lines the caret is on screen (\(pasteInfo))")
}

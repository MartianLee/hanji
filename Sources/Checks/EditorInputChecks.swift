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

    var lineHeight: CGFloat
    var maxLineWidth: CGFloat?
    var textFont = ""
    var codeFont = ""
    var linkTargets: [String] = []
    var isReading = false
    /// False for a split pane that isn't the active one.
    var isLive = true
    var jumpsToTop = false
    /// Top-line offsets the editor reported as it scrolled.
    var viewportTops: [Int] = []

    init?(_ initial: String, cursorOffset initialOffset: Int? = nil, lineHeight: CGFloat = 1.3,
          maxLineWidth: CGFloat? = nil, width: CGFloat = 800, linkTargets: [String] = [],
          isReading: Bool = false) {
        text = initial
        self.linkTargets = linkTargets
        self.isReading = isReading
        cursorOffset = initialOffset
        self.lineHeight = lineHeight
        self.maxLineWidth = maxLineWidth
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        var box: EditorHarness?
        let binding = Binding(get: { box?.text ?? initial }, set: { box?.text = $0 })
        let offset = Binding(get: { box?.cursorOffset ?? initialOffset }, set: { box?.cursorOffset = $0 })
        let host = NSHostingView(rootView: MarkdownEditorView(text: binding, cursorOffset: offset,
                                                              lineHeight: lineHeight, maxLineWidth: maxLineWidth,
                                                              linkTargets: { linkTargets }, isLive: true, isReading: isReading,
                                                              jumpsToTop: false, onViewportTopChange: { box?.viewportTops.append($0) }))
        hosting = host
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        func find(_ v: NSView) -> NSTextView? { (v as? NSTextView) ?? v.subviews.lazy.compactMap(find).first }
        guard let tv = find(window.contentView!) else { return nil }
        textView = tv
        box = self
        // The initial jump happened during the pump above, before `box` existed to
        // take the editor's clearing of it; as in the app, it is spent by now.
        self.cursorOffset = nil
        window.makeFirstResponder(tv)
    }

    func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func key(_ chars: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) {
        window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
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

    /// Hand the editor fresh parameters, as SwiftUI does when a setting changes.
    func rebuild() {
        hosting?.rootView = MarkdownEditorView(text: Binding(get: { self.text }, set: { self.text = $0 }),
                                               cursorOffset: Binding(get: { self.cursorOffset },
                                                                     set: { self.cursorOffset = $0 }),
                                               lineHeight: lineHeight, maxLineWidth: maxLineWidth,
                                               textFont: textFont, codeFont: codeFont,
                                               linkTargets: { self.linkTargets }, isLive: isLive, isReading: isReading,
                                               jumpsToTop: jumpsToTop, onViewportTopChange: { [weak self] in self?.viewportTops.append($0) })
        pump(0.4)
    }

    /// Ask the editor to jump to `offset`, the way search results do.
    func jump(to offset: Int) {
        cursorOffset = offset
        rebuild()
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

    /// Scroll so the line holding `offset` is at the top of the view.
    func scrollToTop(of offset: Int) {
        guard let tlm = textView.textLayoutManager, let tcs = tlm.textContentManager,
              let loc = tcs.location(tcs.documentRange.location, offsetBy: offset),
              let frag = tlm.textLayoutFragment(for: loc) else { return }
        textView.scroll(NSPoint(x: 0, y: frag.layoutFragmentFrame.minY + textView.textContainerOrigin.y))
        pump()
    }

    /// Where the line at the top of the view starts.
    var topLineOffset: Int? {
        guard let tlm = textView.textLayoutManager, let tcs = tlm.textContentManager else { return nil }
        let y = textView.visibleRect.minY - textView.textContainerOrigin.y
        guard let frag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y) + 1)) else { return nil }
        return tcs.offset(from: tcs.documentRange.location, to: frag.rangeInElement.location)
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

/// Typing at the bottom of a long note (below a `---`, at the end) mustn't shake
/// the view: a new line has to be as tall before its first character as after
/// it, or AppKit's scroll-to-caret goes one way on Return and back on the next key.
func editorBottomTypingChecks() {
    var doc: [String] = []
    for i in 0..<120 { doc += ["## Section \(i)", "Paragraph \(i) with **bold**, `code` and a [[link]].", ""] }
    doc += ["---", "Typing at the end"]
    guard let h = EditorHarness(doc.joined(separator: "\n")) else { expect(false, "editor found"); return }
    defer { h.close() }
    let tv = h.textView
    guard let clip = tv.enclosingScrollView?.contentView else { expect(false, "scroll view"); return }
    let end = (tv.string as NSString).length
    h.caret(at: end); tv.scrollRangeToVisible(NSRange(location: end, length: 0)); h.pump(0.4)
    var ys: [CGFloat] = [clip.documentVisibleRect.minY]
    var returnSteps: [CGFloat] = []
    // Every height the view takes while typing, including ones AppKit corrects
    // straight away: off the pixel grid, AppKit rounds it and the two disagree
    // by up to a pixel — a whole point on a 1× screen, where the view jumped.
    var heights: [CGFloat] = []
    tv.postsFrameChangedNotifications = true
    let observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: tv, queue: nil) { _ in
        heights.append(tv.frame.height)
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    for ch in "abc\ndef\nghi jkl\nmno\n" {
        let before = clip.documentVisibleRect.minY
        if ch == "\n" { h.key("\r", 36) } else { h.key(String(ch), 0) }
        h.pump(0.05); h.window.displayIfNeeded()
        let y = clip.documentVisibleRect.minY
        ys.append(y)
        if ch == "\n" { returnSteps.append(y - before) }
    }
    let backwards = zip(ys, ys.dropFirst()).filter { $1 < $0 - 0.5 }.count
    expectEqual(backwards, 0, "typing at the bottom never scrolls back up (scroll positions: \(ys.map { Int($0) }))")
    let scale = h.window.backingScaleFactor
    let offGrid = heights.filter { abs(($0 * scale).rounded() - $0 * scale) > 0.001 }
    expect(offGrid.isEmpty, "the view's height stays on the pixel grid (\(heights.count) heights, off it: \(offGrid))")
    expect((returnSteps.max() ?? 0) - (returnSteps.min() ?? 0) <= 1,
           "every Return scrolls by the same line height (steps: \(returnSteps.map { Int($0) }))")
}

/// Restyling only what changed must give exactly what a full restyle gives. After
/// each edit or caret move, the live editor's attributes are compared with a
/// fresh editor that styled the same text, with the same caret, from scratch.
func incrementalRestyleChecks() {
    let doc = """
    ---
    title: Note
    ---
    # Heading
    Some **bold** and `code` and a [[link]] and #tag.

    | a | b |
    |---|--:|
    | **1** | [[n\\|alias]] |

    - item one
    - [ ] task
    1. first
    > quote
    > [!note] callout
    > inside
    ```swift
    let x = 1
    ```
    ---
    Last paragraph.
    """
    guard let live = EditorHarness(doc) else { expect(false, "editor found"); return }
    defer { live.close() }
    func runs(_ tv: NSTextView) -> [String] {
        guard let s = tv.textStorage else { return [] }
        var out: [String] = []
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, r, _ in
            let keys = attrs.keys.map(\.rawValue).sorted()
            out.append("\(r.location)+\(r.length) " + keys.map { k in "\(k)=\(String(describing: attrs[NSAttributedString.Key(k)]!))" }.joined(separator: ";"))
        }
        return out
    }
    func compare(_ step: String) {
        live.pump(0.15)
        guard let fresh = EditorHarness(live.text) else { expect(false, "fresh editor"); return }
        defer { fresh.close() }
        fresh.textView.setSelectedRange(live.textView.selectedRange())
        fresh.pump(0.2)
        fresh.textView.setSelectedRange(live.textView.selectedRange())   // refresh after the first layout
        fresh.pump(0.2)
        let a = runs(live.textView), b = runs(fresh.textView)
        let firstDiff = zip(a, b).first { $0 != $1 }
        expect(a == b, "after \(step): same attributes as a full restyle (first difference: \(firstDiff.map { "\($0.0) vs \($0.1)" } ?? "run count \(a.count) vs \(b.count)"))")
    }
    let ns = { live.textView.string as NSString }
    func caretAfter(_ s: String) { let r = ns().range(of: s); live.caret(at: r.location + r.length) }

    caretAfter("Some **bold**"); live.type(" more"); compare("typing in a paragraph")
    caretAfter("- item one"); live.type("\n"); compare("Return in a list")
    live.type("second"); compare("typing a list item")
    caretAfter("# Heading"); compare("caret onto a heading")
    caretAfter("- [ ] task"); compare("caret onto a task")
    caretAfter("let x = 1"); live.type(" + 2"); compare("typing in code")
    caretAfter("Last paragraph."); live.key("\u{7f}", 51); live.pump(); compare("delete")
    caretAfter("1. first"); live.type("\n```"); compare("typing a fence")
    live.key("\u{7f}", 51); live.key("\u{7f}", 51); live.key("\u{7f}", 51); live.pump(); compare("deleting the fence")
    caretAfter("> inside"); live.type(" more"); compare("typing in a callout")
    caretAfter("title: Note"); live.type("s"); compare("typing in frontmatter")
    caretAfter("| **1**"); live.type(" x"); compare("typing in a table")
    caretAfter("# Heading"); compare("caret out of a table")
    let delimiterRow = ns().range(of: "|---|--:|\n")
    live.textView.insertText("", replacementRange: delimiterRow); compare("deleting a table's delimiter row")
    live.textView.undoManager?.undo(); compare("undoing it")
    caretAfter("# Heading"); compare("caret away from the table again")
    // A rule that stops being a rule (an opened fence now runs over it) must not
    // keep the rule's reserved, invisible styling.
    let rule = ns().range(of: "\n---\nLast").location + 1
    live.caret(at: rule)
    live.textView.insertText("```\n", replacementRange: live.textView.selectedRange())
    compare("a fence swallowing the rule below")
    live.textView.insertText("\n## Pasted\n- a\n- b\n**x**", replacementRange: live.textView.selectedRange())
    compare("pasting several lines")
    live.textView.undoManager?.undo(); compare("undo")

    // Random edits and caret moves, compared after each one.
    var seed: UInt64 = 0x1234ABCD   // this seed once caught a stale widget reservation
    func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
    let pieces = ["x", "**b**", "`c`", "[[L]]", "- ", "- [ ] ", "# ", "#tag ", "\n", "\n\n", "> ", "```", "---", "1. ", " ", "|", "| x |\n|---|\n"]
    for step in 0..<30 {
        let length = (live.textView.string as NSString).length
        switch next(4) {
        case 0:
            live.caret(at: next(length + 1))
            compare("random step \(step): caret move")
        case 1:
            let at = next(length + 1), cut = min(next(4), length - at)
            live.textView.setSelectedRange(NSRange(location: at, length: max(0, cut)))
            live.textView.insertText("", replacementRange: live.textView.selectedRange())
            compare("random step \(step): delete")
        default:
            live.caret(at: next(length + 1))
            live.textView.insertText(pieces[next(pieces.count)], replacementRange: live.textView.selectedRange())
            compare("random step \(step): insert")
        }
    }
}

/// A keystroke in a long note restyles the paragraphs it touched, not the whole
/// note. (Parsing still reads the whole note — cheap next to restyling, which
/// was ~90% of the cost — so the time grows a little with length, not tenfold.)
func keystrokeCostChecks() {
    func median(lines n: Int) -> Double {
        var doc: [String] = []
        for i in 0..<n { doc += ["## Section \(i)", "Paragraph \(i) with **bold**, `code` and [[link]] #tag.", "- item", ""] }
        guard let h = EditorHarness(doc.joined(separator: "\n")) else { return .infinity }
        defer { h.close() }
        let mid = (h.textView.string as NSString).length / 2
        h.caret(at: mid); h.pump(0.3)
        var times: [Double] = []
        for ch in "typing" {
            let t0 = Date(); h.key(String(ch), 0); times.append(Date().timeIntervalSince(t0))
            h.pump(0.02)
        }
        return times.sorted()[times.count / 2]
    }
    let small = median(lines: 100), large = median(lines: 1000)
    let limit = 0.06 * Check.timeSlack
    expect(large < limit, "a keystroke in a 4,000-line note takes under \(Int(limit * 1000))ms (debug build; took \(Int(large * 1000))ms)")
    expect(large < small * 8 + 0.01,
           "and far from ten times a short note's (\(Int(small * 1000))ms for 400 lines vs \(Int(large * 1000))ms for 4,000)")
}

/// A fenced code block shows its background slab as soon as the note opens —
/// not only after its lines have been edited. (Fragments laid out before the
/// view had a width drew a slab of width < 0: nothing.)
func codeSlabOnOpenChecks() {
    guard let h = EditorHarness("intro line\n```swift\nlet x = 1\n```\nafter line") else { expect(false, "editor found"); return }
    defer { h.close() }
    h.pump(0.3)
    let tv = h.textView
    guard let tlm = tv.textLayoutManager else { return }
    func frame(of needle: String) -> CGRect {
        let off = (tv.string as NSString).range(of: needle).location
        guard let loc = tlm.location(tlm.documentRange.location, offsetBy: off),
              let f = tlm.textLayoutFragment(for: loc) else { return .zero }
        return f.layoutFragmentFrame.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
    }
    func pixel(atRightOf r: CGRect) -> [UInt8] {
        h.window.displayIfNeeded()
        let spot = NSRect(x: tv.bounds.width - tv.textContainerInset.width - 30, y: r.midY - 1, width: 2, height: 2)
        guard let rep = tv.bitmapImageRepForCachingDisplay(in: spot) else { return [] }
        tv.cacheDisplay(in: spot, to: rep)
        return Array(UnsafeBufferPointer(start: rep.bitmapData, count: 4))
    }
    let code = pixel(atRightOf: frame(of: "let x = 1"))
    let plain = pixel(atRightOf: frame(of: "intro line"))
    expect(!code.isEmpty && code != plain, "the code line's slab is painted on open (code \(code) vs plain \(plain))")
}


/// Settings ▸ Appearance: line height applies to body text and to new lines, and
/// readable line length keeps a centred column that follows the window.
func editorAppearanceChecks() {
    guard let h = EditorHarness("Body text here.\n\nMore body.", lineHeight: 1.6) else { expect(false, "editor found"); return }
    defer { h.close() }
    h.pump(0.3)
    func multiple(at i: Int) -> CGFloat {
        (h.textView.textStorage?.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle)?.lineHeightMultiple ?? -1
    }
    expectEqual(multiple(at: 2), 1.6, "body text uses the chosen line height")
    expectEqual((h.textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.lineHeightMultiple, 1.6,
                "and so does a new line")
    h.lineHeight = 1.4; h.rebuild()
    expectEqual(multiple(at: 2), 1.4, "changing it restyles the note")

    guard let wide = EditorHarness(String(repeating: "word ", count: 400), maxLineWidth: 700, width: 1200) else { return }
    defer { wide.close() }
    wide.pump(0.3)
    let tv = wide.textView
    let container = tv.textLayoutManager?.textContainer?.size.width ?? 0
    expect(abs(container - 700) <= 12, "the text column is the readable width (\(Int(container))pt)")
    expect(abs(tv.textContainerOrigin.x - (tv.bounds.width - 700) / 2) <= 12,
           "and centred (\(Int(tv.textContainerOrigin.x))pt in a \(Int(tv.bounds.width))pt view)")
    wide.window.setContentSize(NSSize(width: 1000, height: 600)); wide.pump(0.3)
    expect(abs(tv.textContainerOrigin.x - (tv.bounds.width - 700) / 2) <= 12, "and stays centred when the window resizes")
    wide.maxLineWidth = nil; wide.rebuild()
    expect(tv.textContainerOrigin.x < 40, "turned off, the text uses the full width again (\(Int(tv.textContainerOrigin.x))pt)")
}

/// Settings ▸ Appearance fonts: the text font reaches body, headings, emphasis
/// and new lines; the code font reaches code blocks and inline code; a font
/// that isn't installed falls back to the system's.
func editorFontChecks() {
    let note = "# Title\n\nBody **bold** *slant* `snippet`.\n\n```\nlet x = 1\n```\n"
    guard let h = EditorHarness(note, cursorOffset: (note as NSString).length) else { expect(false, "editor found"); return }
    defer { h.close() }
    h.pump(0.3)
    func font(_ needle: String) -> NSFont? {
        let i = (h.textView.string as NSString).range(of: needle).location
        guard i != NSNotFound else { return nil }
        return h.textView.textStorage?.attribute(.font, at: i + 1, effectiveRange: nil) as? NSFont
    }
    func bold(_ f: NSFont?) -> Bool { f?.fontDescriptor.symbolicTraits.contains(.bold) ?? false }
    func italic(_ f: NSFont?) -> Bool { f?.fontDescriptor.symbolicTraits.contains(.italic) ?? false }
    let system = NSFont.systemFont(ofSize: 15).familyName
    let systemMono = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).familyName
    expectEqual(font("Body")?.familyName, system, "body text is the system font by default")
    expectEqual(font("let x")?.familyName, systemMono, "code is the system monospace by default")

    h.textFont = "Georgia"; h.codeFont = "Menlo"; h.rebuild()
    expectEqual(font("Body")?.familyName, "Georgia", "body text uses the chosen text font")
    expectEqual(font("Title")?.familyName, "Georgia", "so do headings")
    expect(bold(font("Title")), "headings stay bold")
    expectEqual(font("bold")?.familyName, "Georgia", "bold text keeps the family")
    expect(bold(font("bold")), "and is bold")
    expectEqual(font("slant")?.familyName, "Georgia", "italic text keeps the family")
    expect(italic(font("slant")), "and is italic")
    expectEqual((h.textView.typingAttributes[.font] as? NSFont)?.familyName, "Georgia", "a new line is typed in it")
    expectEqual(font("let x")?.familyName, "Menlo", "code blocks use the chosen code font")
    expectEqual(font("snippet")?.familyName, "Menlo", "so does inline code")
    expectEqual(font("Body")?.pointSize, 15, "the font size setting still applies")

    h.textFont = EditorFonts.systemSerif; h.rebuild()
    expect(font("Body")?.fontName.contains("NewYork") ?? false,
           "the system serif is New York (\(font("Body")?.fontName ?? "nil"))")
    expect(bold(font("Title")) && font("Title")?.familyName == font("Body")?.familyName, "with New York bold headings")

    h.textFont = "No Such Font 12345"; h.codeFont = "No Such Mono 12345"; h.rebuild()
    expectEqual(font("Body")?.familyName, system, "a missing text font falls back to the system's")
    expectEqual(font("let x")?.familyName, systemMono, "a missing code font falls back to the system monospace")

    expect(EditorFonts.textFamilies.contains("Georgia"), "installed families are offered for text")
    expect(!EditorFonts.textFamilies.contains { $0.hasPrefix(".") }, "without the system's hidden ones")
    expect(EditorFonts.codeFamilies.contains("Menlo"), "monospaced families are offered for code")
    expect(!EditorFonts.codeFamilies.contains("Georgia"), "proportional ones aren't")
}

/// `[[` completion in the editor: Return or Tab takes a suggestion (↓ moves
/// through them), Esc puts it away and Return is a newline again. A pick is one
/// undo step; inside code there's nothing to complete.
func editorLinkCompletionChecks() {
    guard let h = EditorHarness("", linkTargets: ["Alpha", "Projects/Plan", "Beta"]) else {
        expect(false, "editor found"); return
    }
    defer { h.close() }
    let down = { h.key("\u{F701}", 125) }
    let esc = { h.key("\u{1B}", 53) }
    h.type("See [[al"); h.key("\r", 36); h.pump()
    expectEqual(h.text, "See [[Alpha]]", "Return takes the top suggestion and closes the link")
    expectEqual(h.textView.selectedRange().location, 13, "the caret lands after ]]")

    h.type(" and [[")                         // an empty query lists notes by name
    down(); h.key("\t", 48); h.pump()
    expectEqual(h.text, "See [[Alpha]] and [[Beta]]", "↓ then Tab takes the second")

    h.textView.undoManager?.undo(); h.pump()
    expectEqual(h.text, "See [[Alpha]] and [[", "one undo takes the pick back")

    h.type("pl"); esc(); h.key("\r", 36); h.pump()
    expectEqual(h.text, "See [[Alpha]] and [[pl\n", "Esc puts the list away; Return is a newline again")

    h.type("[[zzz"); h.key("\r", 36); h.pump()
    expect(h.text.hasSuffix("[[zzz\n"), "with nothing to suggest, Return is a newline")

    h.type("[[be"); h.key("\u{F700}", 126); h.key("\r", 36); h.pump()
    expect(h.text.hasSuffix("[[Beta]]"), "↑ wraps around a one-item list")

    guard let code = EditorHarness("```\n", cursorOffset: 4, linkTargets: ["Alpha"]) else { return }
    defer { code.close() }
    code.caret(at: 4)
    code.type("[[al"); code.key("\r", 36); code.pump()
    expectEqual(code.text, "```\n[[al\n", "inside a code block, [[ is just text")
}

/// A code block nested in a list item looks like one: code font, and a slab
/// that starts at the block's indent (a top-level block's still spans the
/// column). Taking the list marker away turns it back into text, although the
/// edit is lines above it.
func editorNestedFenceChecks() {
    let note = "- item\n\n    ```swift\n    Player.all()\n    ```\n\n```\ntop()\n```\n"
    guard let h = EditorHarness(note, cursorOffset: 0) else { expect(false, "editor found"); return }
    defer { h.close() }
    h.pump(0.3)
    func font(_ needle: String) -> NSFont? {
        let i = (h.textView.string as NSString).range(of: needle).location
        return i == NSNotFound ? nil : h.textView.textStorage?.attribute(.font, at: i, effectiveRange: nil) as? NSFont
    }
    expect(font("Player")?.isFixedPitch == true, "nested code is in the code font")
    func slab(_ needle: String) -> (inset: CGFloat, fragment: Bool) {
        guard let tlm = h.textView.textLayoutManager, let tcs = tlm.textContentManager,
              case let i = (h.textView.string as NSString).range(of: needle).location, i != NSNotFound,
              let loc = tcs.location(tcs.documentRange.location, offsetBy: i),
              let fragment = tlm.textLayoutFragment(for: loc) else { return (-1, false) }
        let inset = fragment.responds(to: NSSelectorFromString("slabInset"))
            ? (fragment.value(forKey: "slabInset") as? CGFloat) ?? -1 : -1
        return (inset, String(describing: type(of: fragment)).contains("CodeBlock"))
    }
    let nested = slab("Player"), top = slab("top()")
    expect(nested.fragment && top.fragment, "both blocks draw a slab")
    expect(nested.inset > 10, "the nested slab starts at its indent (\(nested.inset)pt)")
    expectEqual(top.inset, 0, "a top-level slab starts at the margin")

    h.textView.setSelectedRange(NSRange(location: 0, length: 2))
    h.textView.insertText("", replacementRange: NSRange(location: 0, length: 2))
    h.pump(0.3)
    expect(font("Player")?.isFixedPitch == false, "without the list item, the indented fence is text again")
    h.textView.undoManager?.undo(); h.pump(0.3)
    expect(font("Player")?.isFixedPitch == true, "and code once the marker is back")
}

/// A pipe table renders as a grid overlay holding its own height open: the line
/// after it sits just below the grid (no gap for the hidden rows), and the
/// source comes back while the caret is in the table.
func editorTableChecks() {
    let note = "Intro\n\n| Name | Qty |\n|:-----|----:|\n| **apple** | 3 |\n| [[fruit\\|pear]] | 10 |\n| #tag | `x` |\n\nAfter the table"
    guard let h = EditorHarness(note, cursorOffset: 0) else { expect(false, "editor found"); return }
    defer { h.close() }
    h.pump(0.4)
    let tv = h.textView
    func overlays() -> [NSView] { tv.subviews.filter { $0 is NSHostingView<AnyView> } }
    func lineTop(_ needle: String) -> CGFloat {
        let i = (tv.string as NSString).range(of: needle).location
        let screen = tv.firstRect(forCharacterRange: NSRange(location: i, length: 1), actualRange: nil)
        guard let window = tv.window else { return -1 }
        let inWindow = window.convertFromScreen(screen)
        return tv.convert(inWindow, from: nil).minY
    }
    guard let grid = overlays().first else { expect(false, "the table is drawn as an overlay"); return }
    expectEqual(overlays().count, 1, "one overlay, for the table")
    expect(grid.frame.height > 80 && grid.frame.height < 250, "grid holds the height of four rows (\(grid.frame.height)pt)")
    let after = lineTop("After the table")
    expect(after >= grid.frame.maxY - 1, "the next line is below the grid (\(after) vs \(grid.frame.maxY))")
    expect(after - grid.frame.maxY < 45, "with no gap left by the hidden rows (\(after - grid.frame.maxY)pt)")
    if let path = ProcessInfo.processInfo.environment["HANJI_TABLE_PNG"],
       let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds) {
        tv.cacheDisplay(in: tv.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    h.caret(at: (tv.string as NSString).range(of: "apple").location); h.pump(0.3)
    expectEqual(overlays().count, 0, "caret in the table shows its source")
    expect(lineTop("After the table") > lineTop("| #tag"), "source rows are laid out again")
    h.caret(at: 0); h.pump(0.3)
    expectEqual(overlays().count, 1, "caret out: the grid is back")

    // Breaking the delimiter row turns the rows back into plain text.
    let delimiter = (tv.string as NSString).range(of: "|:-----|----:|")
    tv.insertText("", replacementRange: NSRange(location: delimiter.location, length: delimiter.length + 1))
    h.caret(at: 0); h.pump(0.3)
    expectEqual(overlays().count, 0, "no delimiter row, no table")
    let font = tv.textStorage?.attribute(.font, at: (tv.string as NSString).range(of: "Name").location, effectiveRange: nil) as? NSFont
    expect((font?.pointSize ?? 0) > 5, "and its former header is visible text again")
}

/// Return inside a code block keeps the line's indentation, as a code editor
/// does — above all in a block nested in a list item, where every line starts
/// with the fence's indent. Outside code, Return is unchanged.
func editorCodeIndentChecks() {
    func afterReturn(_ note: String, at needle: String, type extra: String = "") -> (text: String, caret: Int)? {
        let caret = NSMaxRange((note as NSString).range(of: needle))
        guard let h = EditorHarness(note, cursorOffset: caret) else { return nil }
        defer { h.close() }
        h.caret(at: caret); h.pump(0.2)
        h.key("\r", 36); h.pump()
        if !extra.isEmpty { h.type(extra) }
        return (h.text, h.textView.selectedRange().location)
    }
    let nested = "- item\n\n    ```swift\n    let a = 1\n    ```\n"
    expectEqual(afterReturn(nested, at: "let a = 1", type: "b")?.text,
                "- item\n\n    ```swift\n    let a = 1\n    b\n    ```\n",
                "in a nested block, the next line starts at the block's indent")
    expectEqual(afterReturn(nested, at: "```swift")?.text,
                "- item\n\n    ```swift\n    \n    let a = 1\n    ```\n", "so does Return on its opening fence")
    expectEqual(afterReturn("- a\n\t```\n\tx\n\t```", at: "\tx")?.text, "- a\n\t```\n\tx\n\t\n\t```", "tabs stay tabs")
    let deeper = "- a\n    ```\n    if x {\n        y\n    }\n    ```"
    expectEqual(afterReturn(deeper, at: "        y")?.text, "- a\n    ```\n    if x {\n        y\n        \n    }\n    ```",
                "a deeper line keeps its own depth")
    let top = "```\n  foo\n```"
    expectEqual(afterReturn(top, at: "  foo")?.text, "```\n  foo\n  \n```", "at the top level too")
    let r = afterReturn(top, at: "  foo")
    expectEqual(r?.caret, ("```\n  foo\n  " as NSString).length, "the caret lands after the indent")

    // Unchanged.
    expectEqual(afterReturn("```\nfoo\n```", at: "foo")?.text, "```\nfoo\n\n```", "an unindented code line: a plain newline")
    expectEqual(afterReturn("  text", at: "text")?.text, "  text\n", "outside code, indentation isn't carried")
    expectEqual(afterReturn("- item", at: "item")?.text, "- item\n- ", "a list item still continues")
    expectEqual(afterReturn("```\n    x\n```", at: "```\n")?.text, "```\n\n    x\n```",
                "Return before a line's indent just splits it")

    guard let h = EditorHarness(nested, cursorOffset: NSMaxRange((nested as NSString).range(of: "let a = 1"))) else { return }
    defer { h.close() }
    h.caret(at: NSMaxRange((nested as NSString).range(of: "let a = 1"))); h.pump(0.2)
    h.key("\r", 36); h.pump()
    h.textView.undoManager?.undo(); h.pump()
    expectEqual(h.text, nested, "one undo takes the new line and its indent back")
}

/// What a keystroke costs, in work rather than time (the same on any machine):
/// in a note full of widgets — code blocks, rules, tables — typing, Return and
/// moving the caret restyle only the lines they touch, build no new widget
/// views, and refresh once. Typing above a widget used to make it look gone
/// (widgets were matched by offset), which restyled the whole note and rebuilt
/// every widget below on each key; Return, with a code block below, restyled
/// everything too.
func keystrokeWorkChecks() {
    var lines: [String] = [], i = 0
    while lines.count < 1000 {
        lines += ["## Section \(i)", "Paragraph \(i) with **bold** and `code` text.", "- item", ""]
        if i % 15 == 3 { lines += ["```swift", "let value = \(i)", "```", ""] }
        if i % 21 == 7 { lines += ["---", ""] }
        if i % 25 == 11 { lines += ["| a | b |", "|---|---|", "| \(i) | x |", ""] }
        i += 1
    }
    let text = lines.joined(separator: "\n")
    let length = (text as NSString).length
    guard let h = EditorHarness(text) else { expect(false, "editor found"); return }
    defer { h.close() }
    let paragraph = (text as NSString).range(of: "Paragraph 20 with").location + 10
    h.caret(at: paragraph); h.pump(0.5)
    func work(_ label: String, _ action: () -> Void) {
        EditorMetrics.reset()
        action(); h.pump(0.2)
        expectEqual(EditorMetrics.fullRestyles, 0, "\(label): no full restyle")
        expect(EditorMetrics.restyledCharacters < length / 50,
               "\(label): restyles only nearby lines (\(EditorMetrics.restyledCharacters) of \(length) characters)")
        expectEqual(EditorMetrics.widgetViewsCreated, 0, "\(label): builds no widget views")
    }
    work("typing above widgets") { h.key("x", 0) }
    expectEqual(EditorMetrics.refreshes, 1, "a keystroke refreshes once")
    work("Return with a code block below") { h.key("\r", 36) }
    work("moving the caret a line") { h.key("\u{F701}", 125) }
    expect(EditorMetrics.reservationWrites < 10,
           "and rewrites no widget heights that didn't change (\(EditorMetrics.reservationWrites) writes)")
}

/// Where the caret is and whether it can be seen, after the moves that lost it
/// in a long note: ⌘↓ to the end (the caret on the last, empty line, below the
/// bottom of a view whose height hadn't caught up), and arrowing up from there
/// (the caret moved, the view didn't follow).
func editorCaretTrackingChecks() {
    var lines: [String] = []
    for i in 0..<1000 { lines += ["## Section \(i)", "Paragraph \(i) with **bold** text and more words to wrap a little.", "- item", ""] }
    guard let h = EditorHarness(lines.joined(separator: "\n"), cursorOffset: 0) else { expect(false, "editor found"); return }
    defer { h.close() }
    let tv = h.textView
    h.caret(at: 0); h.pump(0.5)
    func caret() -> String {
        let rect = tv.convert(h.window.convertFromScreen(tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)), from: nil)
        return "caret y \(Int(rect.minY))–\(Int(rect.maxY)), view \(Int(tv.visibleRect.minY))–\(Int(tv.visibleRect.maxY)), height \(Int(tv.frame.height))"
    }
    h.key("\u{F701}", 125, [.command, .numericPad, .function]); h.pump(0.6)
    expectEqual(tv.selectedRange().location, (tv.string as NSString).length, "⌘↓ goes to the end")
    expect(h.caretInView.0, "and the caret there is in view (\(caret()))")
    let usage = tv.textLayoutManager?.usageBoundsForTextContainer.maxY ?? 0
    expect(tv.frame.height >= usage, "the view is as tall as its laid-out text (\(Int(tv.frame.height)) vs \(Int(usage)))")
    for _ in 0..<30 { h.key("\u{F700}", 126, [.numericPad, .function]); h.pump(0.06) }
    h.pump(0.6)
    expect(h.caretInView.0, "arrowing up 30 lines from the end keeps the caret in view (\(caret()))")
    h.key("\u{F700}", 126, [.command, .numericPad, .function]); h.pump(0.6)
    expect(tv.selectedRange().location == 0 && h.caretInView.0, "⌘↑ goes back to the top, in view (\(caret()))")
}

/// Only a code block's own lines draw its slab — never the lines above it, after
/// an edit shifts the block (typing or composing Hangul in a heading above it,
/// deleting a line above it).
func codeSlabStaysOnCodeChecks() {
    func isSlab(_ h: EditorHarness, lineAt i: Int) -> Bool {
        guard let tlm = h.textView.textLayoutManager, let tcs = tlm.textContentManager,
              let loc = tcs.location(tcs.documentRange.location, offsetBy: i),
              let fragment = tlm.textLayoutFragment(for: loc) else { return false }
        return String(describing: type(of: fragment)).contains("CodeBlock")
    }
    func check(_ label: String, _ note: String, edit: (EditorHarness) -> Void) {
        guard let h = EditorHarness(note, cursorOffset: 0) else { expect(false, "editor found"); return }
        defer { h.close() }
        h.pump(0.3)
        edit(h)
        h.pump(0.3)
        let ns = h.textView.string as NSString
        let fence = ns.range(of: "```").location
        var bad: [Int] = []
        var i = 0
        while i < fence {
            let para = ns.paragraphRange(for: NSRange(location: i, length: 0))
            if isSlab(h, lineAt: i) { bad.append(i) }
            i = NSMaxRange(para)
        }
        expect(bad.isEmpty, "\(label): no slab above the fence (slab lines at \(bad), fence at \(fence))")
        expect(isSlab(h, lineAt: fence), "\(label): the fence line draws the slab")
    }
    let note = "## Notes \n\n\n## 결과\n\n```\n콘텐츠 노출\n최근 업데이트\n```\n"
    check("typed above", note) { h in
        h.caret(at: (note as NSString).range(of: "결과").location + 2); h.type("abc")
    }
    check("deleted above", note) { h in
        h.caret(at: 10); h.key("\u{7f}", 51); h.pump()
    }
    check("composed above", note) { h in
        let at = (note as NSString).range(of: "결과").location + 2
        h.caret(at: at)
        for step in ["ㅎ", "하", "한", "한ㄱ", "한그", "한글"] {
            h.textView.setMarkedText(step, selectedRange: NSRange(location: (step as NSString).length, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
            h.pump(0.05)
        }
        h.textView.insertText("한글", replacementRange: h.textView.markedRange())
    }
    check("composed then deleted above", note) { h in
        let at = (note as NSString).range(of: "결과").location + 2
        h.caret(at: at)
        for step in ["ㅎ", "하", "한"] {
            h.textView.setMarkedText(step, selectedRange: NSRange(location: (step as NSString).length, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
            h.pump(0.05)
        }
        h.textView.insertText("한", replacementRange: h.textView.markedRange())
        h.pump()
        for _ in 0..<3 { h.key("\u{7f}", 51) }
        h.pump()
    }
}

/// Same for a list's bullets: composing Hangul above a list mustn't leave a
/// bullet drawn on a line that has none.
func markerStaysOnListChecks() {
    // One composed character moves the blank line onto the item's old offset.
    let note = "## 결과\n\n- item\n"
    guard let h = EditorHarness(note, cursorOffset: 0) else { expect(false, "editor found"); return }
    defer { h.close() }
    h.pump(0.3)
    h.caret(at: 5)
    for step in ["ㅎ", "하", "한"] {
        h.textView.setMarkedText(step, selectedRange: NSRange(location: (step as NSString).length, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        h.pump(0.05)
    }
    h.textView.insertText("한", replacementRange: h.textView.markedRange())
    h.pump(0.3)
    func isMarker(_ needle: String) -> Bool {
        guard let tlm = h.textView.textLayoutManager, let tcs = tlm.textContentManager,
              case let i = (h.textView.string as NSString).range(of: needle).location + (needle == "\n\n" ? 1 : 0),
              i != NSNotFound,
              let loc = tcs.location(tcs.documentRange.location, offsetBy: i),
              let fragment = tlm.textLayoutFragment(for: loc) else { return false }
        return String(describing: type(of: fragment)).contains("Marker")
    }
    expect(!isMarker("\n\n"), "no bullet on the blank line above the list after composing above it")
    expect(isMarker("- item"), "the list item keeps its bullet")
}

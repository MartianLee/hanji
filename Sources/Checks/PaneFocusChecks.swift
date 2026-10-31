import AppKit
import SwiftUI
import AppCore
import EditorEngine
import MKSearchKit

/// The panes of a split, wired to the editor the way ContentView's `paneView`
/// wires them: the active pane edits the live buffer, the other one shows a
/// snapshot, focusing an editor makes its pane the active one, and each
/// editor starts where its tab was left.
private struct SplitEditors: View {
    @ObservedObject var appState: AppState
    var body: some View {
        HStack(spacing: 0) {
            ForEach(appState.panes) { pane in
                let isActive = pane.id == appState.activePaneID
                if let tab = pane.tabs.first(where: { $0.id == pane.activeTabID }) {
                    MarkdownEditorView(
                        text: isActive ? $appState.activeText : .constant(tab.text),
                        cursorOffset: $appState.pendingCursorOffset,
                        onFocus: { appState.focusPane(pane.id) },
                        isLive: isActive,
                        onCaretMove: { appState.caretMoved(to: $0) },
                        jumpsToTop: isActive && appState.pendingJumpToTop,
                        jumpTopLine: isActive ? appState.pendingJumpTopLine : nil,
                        onViewportTopChange: { appState.viewportMoved(top: $0, inTab: tab.id) },
                        startCaret: tab.position.caret, startTopLine: tab.position.top)
                }
            }
        }
    }
}

/// A window showing `SplitEditors` for an AppState, and the left and right
/// editors in it (`panes: 1` — one pane, its editor as `left`).
private final class SplitHarness {
    let window: NSWindow
    let views: [NSTextView]

    init?(_ state: AppState, panes: Int = 2) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SplitEditors(appState: state))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        func find(_ v: NSView) -> [NSTextView] { (v as? NSTextView).map { [$0] } ?? v.subviews.flatMap(find) }
        views = find(window.contentView!).sorted {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        }
        guard views.count == panes else { expect(false, "setup: \(panes) editor(s), found \(views.count)"); return nil }
    }

    var left: NSTextView { views[0] }
    var right: NSTextView { views[1] }

    func pump(_ t: Double = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    /// A pane that has never been the active one may not be laid out for real
    /// yet (a reader scrolling it would lay it out as they go): lay it out, and
    /// make the view as tall as that, as the editor's own layOutNote does.
    func frame(of offset: Int, in tv: NSTextView) -> NSRect? {
        guard let tlm = tv.textLayoutManager, let tcs = tlm.textContentManager else { return nil }
        tlm.ensureLayout(for: tlm.documentRange)
        let height = tlm.usageBoundsForTextContainer.maxY + tv.textContainerInset.height * 2
        if tv.frame.height < height { tv.setFrameSize(NSSize(width: tv.frame.width, height: height)) }
        guard let loc = tcs.location(tcs.documentRange.location, offsetBy: offset),
              let frag = tlm.textLayoutFragment(for: loc) else { return nil }
        return frag.layoutFragmentFrame.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
    }

    func scroll(_ tv: NSTextView, toLineOf offset: Int) {
        guard let f = frame(of: offset, in: tv) else { return }
        tv.scroll(NSPoint(x: 0, y: f.minY))
        pump()
    }

    /// Where the line at the top of `tv`'s view starts.
    func topLine(_ tv: NSTextView) -> Int? {
        guard let tlm = tv.textLayoutManager, let tcs = tlm.textContentManager else { return nil }
        let y = tv.visibleRect.minY - tv.textContainerOrigin.y
        guard let frag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y) + 1)) else { return nil }
        return tcs.offset(from: tcs.documentRange.location, to: frag.rangeInElement.location)
    }

    func click(_ tv: NSTextView, atLineOf offset: Int) {
        guard let f = frame(of: offset, in: tv) else { expect(false, "no line to click"); return }
        let p = tv.convert(NSPoint(x: f.minX + 30, y: f.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        // What a key window does with a press: the view under it becomes first
        // responder, then gets the event. (This process can't make its window
        // key, and a window that isn't treats a click as one to activate it.)
        // The text view tracks the press until the release, which it takes from the queue.
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.makeFirstResponder(tv)
        tv.mouseDown(with: event(.leftMouseDown))
        pump()
    }

    func type(_ chars: String) {
        window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: chars,
                                          charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 6)!)
        pump()
    }
}

/// A vault holding a long note per name ("## Name 0" … "## Name 199", each
/// with a line of text under it), and the notes' text.
private func longNoteVault(_ tag: String, _ names: [String: String]) -> (URL, [String: String]) {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-\(tag)-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    var texts: [String: String] = [:]
    for (file, heading) in names {
        let text = (0..<200).map { "## \(heading) \($0)\ntext under \($0)\n" }.joined()
        try? text.write(to: vault.appendingPathComponent(file), atomically: true, encoding: .utf8)
        texts[file] = text
    }
    return (vault, texts)
}

private func offset(of line: String, in text: String) -> Int { (text as NSString).range(of: line + "\n").location }

/// Moving into the other pane of a split — a click anywhere in its text, or on
/// its tab — makes that pane the active one and leaves it where it was: the
/// scroll stays, a click puts the caret where it landed, and typing goes there.
/// (It used to jump the pane to its top with the caret at the start, so the
/// only way across without losing your place was not to cross at all.)
func paneFocusChecks() {
    let (vault, texts) = longNoteVault("panefocus", ["A.md": "Left", "B.md": "Right"])
    defer { try? FileManager.default.removeItem(at: SearchIndex.indexFileURL(forVault: vault))
            try? FileManager.default.removeItem(at: vault) }
    let (left, right) = (texts["A.md"]!, texts["B.md"]!)
    let suite = "mk-panefocus-\(UUID().uuidString)"
    let s = AppState(defaults: UserDefaults(suiteName: suite)!)
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    s.openVault(at: vault)
    s.openNote(relativePath: "A.md", newTab: true)
    s.openNote(relativePath: "B.md", newTab: true)
    s.moveTabToSide(s.activeTabID!, .right)            // [[A], [B]], the right pane active
    guard s.panes.count == 2 else { expect(false, "setup: two panes"); return }
    let leftPane = s.panes[0].id, rightPane = s.panes[1].id
    guard let h = SplitHarness(s) else { return }
    defer { h.window.close() }
    h.window.makeFirstResponder(h.right)
    h.pump()

    // The inactive left pane, scrolled down the note, gets a click in its text.
    let leftTop = offset(of: "## Left 100", in: left)
    let leftClicked = offset(of: "## Left 104", in: left)
    h.scroll(h.left, toLineOf: leftTop)
    expectEqual(h.topLine(h.left), leftTop, "setup: the left pane is scrolled to its line 100")
    var carets: [Int] = []
    let token = s.focusOffset.sink { carets.append($0) }
    defer { token.cancel() }
    h.click(h.left, atLineOf: leftClicked)
    h.pump(0.4)
    expectEqual(s.activePaneID, leftPane, "a click in the other pane's text makes it the active pane")
    expectEqual(h.topLine(h.left), leftTop, "and the pane stays where it was scrolled")
    let caret = h.left.selectedRange().location
    expect(caret >= leftClicked && caret <= leftClicked + "## Left 104".count,
           "the caret goes where the click landed (\(caret), line at \(leftClicked))")
    expect(h.window.firstResponder === h.left, "typing goes to the clicked pane")
    expectEqual(carets.last, caret, "the app knows where that pane's caret is (outline, Back)")

    // What's typed there lands in its note.
    h.type("Z")
    expect(s.activeText.contains("Z") && s.selectedFile?.name == "A.md", "a key typed after the click edits the left note")
    expect(!(s.panes[1].tabs.first?.text.contains("Z") ?? true), "and not the right one")

    // Back across by its tab (TabBarView: focus the pane, switch to the tab it shows).
    let rightTop = offset(of: "## Right 60", in: right)
    h.scroll(h.right, toLineOf: rightTop)
    s.focusPane(rightPane)
    if let shown = s.panes[1].activeTabID { s.switchTab(shown) }
    h.pump(0.4)
    expectEqual(s.activePaneID, rightPane, "its tab makes the right pane active")
    expectEqual(h.topLine(h.right), rightTop, "and it too stays where it was scrolled")
    expect(h.window.firstResponder === h.right, "typing follows to the right pane")
    expectEqual(carets.last, h.right.selectedRange().location, "and the app learns that pane's caret")
    expectEqual(h.topLine(h.left), leftTop, "the left pane, left behind, doesn't move either")
}

/// Reopening the vault brings both panes of a split back where they were: the
/// active pane through its jump, the other one through its editor's start
/// position (jumps only reach the active pane).
func workspaceRestoreEditorsChecks() {
    let (vault, texts) = longNoteVault("restore-editors", ["A.md": "Left", "B.md": "Right"])
    defer { try? FileManager.default.removeItem(at: SearchIndex.indexFileURL(forVault: vault))
            try? FileManager.default.removeItem(at: vault) }
    let (left, right) = (texts["A.md"]!, texts["B.md"]!)
    let suite = "mk-restore-editors-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let leftTop = offset(of: "## Left 100", in: left), leftCaret = offset(of: "## Left 104", in: left) + 3
    let rightTop = offset(of: "## Right 60", in: right), rightCaret = offset(of: "## Right 62", in: right) + 4

    // The session before: what the editors would have reported as the reader worked.
    let before = AppState(defaults: UserDefaults(suiteName: suite)!)
    before.openVault(at: vault)
    before.openNote(relativePath: "A.md", newTab: true)
    before.openNote(relativePath: "B.md", newTab: true)
    before.moveTabToSide(before.activeTabID!, .right)
    before.caretMoved(to: rightCaret)
    before.viewportMoved(top: rightTop)
    before.focusPane(before.panes[0].id)
    before.caretMoved(to: leftCaret)
    before.viewportMoved(top: leftTop)
    _ = before.saveAllForClose()

    let s = AppState(defaults: UserDefaults(suiteName: suite)!)
    s.openVault(at: vault)
    guard s.panes.count == 2 else { expect(false, "the split comes back (\(s.panes.count) panes)"); return }
    guard let h = SplitHarness(s) else { return }
    defer { h.window.close() }
    h.pump(0.6)
    expectEqual(h.topLine(h.left), leftTop, "the active left pane is back at its line 100")
    expectEqual(h.left.selectedRange().location, leftCaret, "with its caret where it was")
    expectEqual(h.topLine(h.right), rightTop, "the right pane is back at its line 60")
    expectEqual(h.right.selectedRange().location, rightCaret, "with its caret where it was")
    expect(h.window.firstResponder !== h.right, "the inactive pane doesn't take the keyboard")
}

/// Clicking another tab and then back: the first tab comes back where it was
/// left — scrolled to the same line, the caret where it was — not at the top.
func tabSwitchKeepsPlaceChecks() {
    let (vault, texts) = longNoteVault("tabswitch", ["A.md": "Left", "B.md": "Right"])
    defer { try? FileManager.default.removeItem(at: SearchIndex.indexFileURL(forVault: vault))
            try? FileManager.default.removeItem(at: vault) }
    let (left, right) = (texts["A.md"]!, texts["B.md"]!)
    let suite = "mk-tabswitch-\(UUID().uuidString)"
    let s = AppState(defaults: UserDefaults(suiteName: suite)!)
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    s.openVault(at: vault)
    s.openNote(relativePath: "A.md", newTab: true)
    s.openNote(relativePath: "B.md", newTab: true)
    let (a, b) = (s.tabs[0].id, s.tabs[1].id)
    s.switchTab(a)
    guard let h = SplitHarness(s, panes: 1) else { return }
    defer { h.window.close() }
    let editor = h.left

    let aTop = offset(of: "## Left 100", in: left)
    h.scroll(editor, toLineOf: aTop)
    h.click(editor, atLineOf: offset(of: "## Left 104", in: left))
    let aCaret = editor.selectedRange().location
    h.pump(0.3)
    expectEqual(h.topLine(editor), aTop, "setup: A scrolled to its line 100")

    s.switchTab(b)                                   // TabBarView's click on B
    h.pump(0.5)
    expect(editor.string.hasPrefix("## Right 0"), "setup: B is showing")
    let bTop = offset(of: "## Right 40", in: right)
    h.scroll(editor, toLineOf: bTop)
    h.pump(0.3)

    s.switchTab(a)                                   // and back on A
    h.pump(0.5)
    expectEqual(h.topLine(editor), aTop, "A comes back at the line it was scrolled to, not the top")
    expectEqual(editor.selectedRange().location, aCaret, "with its caret where it was")
    s.switchTab(b)
    h.pump(0.5)
    expectEqual(h.topLine(editor), bTop, "and so does B")
}

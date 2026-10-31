import AppKit
import SwiftUI
import AppCore
import EditorEngine
import MKSearchKit

/// The two panes of a split, wired to the editor the way ContentView's
/// `paneView` wires them: the active pane edits the live buffer, the other one
/// shows a snapshot, and focusing an editor makes its pane the active one.
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
                        onViewportTopChange: { appState.viewportMoved(top: $0) })
                }
            }
        }
    }
}

/// Moving into the other pane of a split — a click anywhere in its text, or on
/// its tab — makes that pane the active one and leaves it where it was: the
/// scroll stays, a click puts the caret where it landed, and typing goes there.
/// (It used to jump the pane to its top with the caret at the start, so the
/// only way across without losing your place was not to cross at all.)
func paneFocusChecks() {
    _ = NSApplication.shared
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-panefocus-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)); try? fm.removeItem(at: vault) }
    func note(_ name: String) -> String { (0..<200).map { "## \(name) \($0)\ntext under \($0)\n" }.joined() }
    let left = note("Left"), right = note("Right")
    try? left.write(to: vault.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
    try? right.write(to: vault.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
    let suite = "mk-panefocus-\(UUID().uuidString)"
    let s = AppState(defaults: UserDefaults(suiteName: suite)!)
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    s.openVault(at: vault)
    s.openNote(relativePath: "A.md", newTab: true)
    s.openNote(relativePath: "B.md", newTab: true)
    s.moveTabToSide(s.activeTabID!, .right)            // [[A], [B]], the right pane active
    guard s.panes.count == 2 else { expect(false, "setup: two panes"); return }
    let leftPane = s.panes[0].id, rightPane = s.panes[1].id

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: SplitEditors(appState: s))
    window.makeKeyAndOrderFront(nil)
    func pump(_ t: Double = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
    pump(0.6)
    func find(_ v: NSView) -> [NSTextView] { (v as? NSTextView).map { [$0] } ?? v.subviews.flatMap(find) }
    let views = find(window.contentView!).sorted {
        $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
    }
    guard views.count == 2 else { expect(false, "setup: two editors, found \(views.count)"); return }
    let (leftView, rightView) = (views[0], views[1])
    window.makeFirstResponder(rightView)
    pump()

    // A pane that has never been the active one may not be laid out for real
    // yet (a reader scrolling it would lay it out as they go): lay it out, and
    // make the view as tall as that, as the editor's own layOutNote does.
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
    func offset(of line: String, in text: String) -> Int { (text as NSString).range(of: line + "\n").location }

    // The inactive left pane, scrolled down the note, gets a click in its text.
    let leftTop = offset(of: "## Left 100", in: left)
    let leftClicked = offset(of: "## Left 104", in: left)
    scroll(leftView, toLineOf: leftTop)
    expectEqual(topLine(leftView), leftTop, "setup: the left pane is scrolled to its line 100")
    var carets: [Int] = []
    let token = s.focusOffset.sink { carets.append($0) }
    defer { token.cancel() }
    click(leftView, atLineOf: leftClicked)
    pump(0.4)
    expectEqual(s.activePaneID, leftPane, "a click in the other pane's text makes it the active pane")
    expectEqual(topLine(leftView), leftTop, "and the pane stays where it was scrolled")
    let caret = leftView.selectedRange().location
    expect(caret >= leftClicked && caret <= leftClicked + "## Left 104".count,
           "the caret goes where the click landed (\(caret), line at \(leftClicked))")
    expect(window.firstResponder === leftView, "typing goes to the clicked pane")
    expectEqual(carets.last, caret, "the app knows where that pane's caret is (outline, Back)")

    // What's typed there lands in its note.
    window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "Z",
                                      charactersIgnoringModifiers: "Z", isARepeat: false, keyCode: 6)!)
    pump()
    expect(s.activeText.contains("Z") && s.selectedFile?.name == "A.md", "a key typed after the click edits the left note")
    expect(!(s.panes[1].tabs.first?.text.contains("Z") ?? true), "and not the right one")

    // Back across by its tab (TabBarView: focus the pane, switch to the tab it shows).
    let rightTop = offset(of: "## Right 60", in: right)
    scroll(rightView, toLineOf: rightTop)
    s.focusPane(rightPane)
    if let shown = s.panes[1].activeTabID { s.switchTab(shown) }
    pump(0.4)
    expectEqual(s.activePaneID, rightPane, "its tab makes the right pane active")
    expectEqual(topLine(rightView), rightTop, "and it too stays where it was scrolled")
    expect(window.firstResponder === rightView, "typing follows to the right pane")
    expectEqual(carets.last, rightView.selectedRange().location, "and the app learns that pane's caret")
    expectEqual(topLine(leftView), leftTop, "the left pane, left behind, doesn't move either")
    window.close()
}

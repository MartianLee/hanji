import AppKit
import SwiftUI
import AppCore
import EditorEngine
import MKSearchKit
import VaultKit

/// Reading mode belongs to the tab: it survives navigating in the tab and moving
/// it to the other pane, new tabs start in editing, and a pinned tab brings it
/// back when the vault reopens.
func readingTabChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-read-\(UUID().uuidString)")
    let other = fm.temporaryDirectory.appendingPathComponent("mk-read-other-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    try? fm.createDirectory(at: other, withIntermediateDirectories: true)
    defer {
        for v in [vault, other] {
            try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: v)); try? fm.removeItem(at: v)
        }
    }
    for name in ["A.md", "B.md", "C.md"] {
        try? name.write(to: vault.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let suite = "mk-read-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let s = AppState(defaults: defaults)
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    s.openVault(at: vault)
    func tab(_ name: String) -> OpenTab? { s.panes.flatMap(\.tabs).first { $0.file.name == name } }
    func file(_ name: String) -> MarkdownFile { s.files.first { $0.name == name }! }

    s.openNote(relativePath: "A.md", newTab: true)
    s.openNote(relativePath: "C.md", newTab: true)
    s.toggleReading(tab("A.md")!.id)
    expect(tab("A.md")?.isReading == true, "a tab can be put in reading mode")
    expect(tab("C.md")?.isReading == false, "the other tab stays in editing")
    expect(!s.isActiveTabReading, "the active tab (C) is editing")
    s.switchTab(tab("A.md")!.id)
    expect(s.isActiveTabReading, "the active tab (A) is reading")

    s.open(file("B.md"))                       // a link followed in the same tab
    expect(tab("B.md")?.isReading == true, "following a link keeps the tab reading")
    s.goBack()
    expect(tab("A.md")?.isReading == true, "and so does going back")

    s.openNote(relativePath: "B.md", newTab: true)
    expect(tab("B.md")?.isReading == false, "a new tab opens in editing")

    s.moveTabToSide(tab("A.md")!.id, .right)
    expect(s.panes.count == 2 && s.panes[1].tabs.first?.isReading == true, "moving a tab to the other pane keeps it reading")

    // Remembered for pinned tabs only.
    s.togglePin(tab("A.md")!.id)
    s.togglePin(tab("C.md")!.id)
    s.toggleReading(tab("B.md")!.id)           // reading, but not pinned
    let key = "io.hanji.reading.\(vault.standardizedFileURL.path)"
    expectEqual(defaults.stringArray(forKey: key), ["A.md"], "only pinned reading tabs are stored")
    s.openVault(at: other); s.openVault(at: vault)
    expect(tab("A.md")?.isReading == true, "a pinned reading tab comes back reading")
    expect(tab("C.md")?.isReading == false, "a pinned editing tab comes back editing")

    _ = try? s.rename(vault.appendingPathComponent("A.md"), to: "Renamed")
    s.openVault(at: other); s.openVault(at: vault)
    expect(tab("Renamed.md")?.isReading == true, "a rename carries the mode along")
}

/// Moving a reading tab onto a pane that already shows the same note merges the
/// two tabs; the survivor takes the moved tab's mode rather than keeping its own.
func readingTabMergeChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-read-merge-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer {
        try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)); try? fm.removeItem(at: vault)
    }
    try? "A".write(to: vault.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
    let suite = "mk-read-merge-\(UUID().uuidString)"
    let s = AppState(defaults: UserDefaults(suiteName: suite)!)
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    s.openVault(at: vault)
    s.openNote(relativePath: "A.md", newTab: true)
    s.splitRight()                              // the same note in a second pane
    guard s.panes.count == 2, let moving = s.panes[0].tabs.first, let staying = s.panes[1].tabs.first else {
        expect(false, "two panes show the note"); return
    }
    expect(moving.buffer === staying.buffer, "both panes share the note's buffer")
    s.toggleReading(moving.id)
    expect(!staying.isReading, "the other pane's tab is editing")
    s.moveTabToSide(moving.id, .right)
    expectEqual(s.panes.count, 1, "the emptied pane collapses")
    expectEqual(s.panes.first?.tabs.count, 1, "the two tabs merged into one")
    expect(s.panes.first?.tabs.first?.isReading == true, "the surviving tab takes the moved tab's reading mode")
}

/// Reading mode draws the caret's line like every other line — markers hidden,
/// widgets drawn — and the text view takes no typing. Back in editing, the
/// caret's line shows its source again.
func editorReadingChecks() {
    let note = "Intro\n\nSome **bold** text\n\n---\n\nAfter"
    let bold = (note as NSString).range(of: "**bold**").location
    let rule = (note as NSString).range(of: "---").location
    guard let h = EditorHarness(note) else { expect(false, "editor found"); return }
    defer { h.close() }
    let tv = h.textView
    func markerSize() -> CGFloat {
        (tv.textStorage?.attribute(.font, at: bold, effectiveRange: nil) as? NSFont)?.pointSize ?? -1
    }
    func overlays() -> Int { tv.subviews.filter { $0 is NSHostingView<AnyView> }.count }

    h.caret(at: rule); h.pump(0.3)
    expectEqual(overlays(), 0, "editing: the rule under the caret shows its source")
    expect(markerSize() < 1, "editing: a line without the caret hides its ** (\(markerSize())pt)")
    h.caret(at: bold + 3); h.pump(0.3)
    expect(markerSize() > 5, "editing: the caret's line shows its ** (\(markerSize())pt)")
    // Switching to reading with the caret on that line restyles it: the markers must hide.
    h.isReading = true; h.rebuild()
    expect(markerSize() < 1, "reading: the caret's line hides them too, switching in on it (\(markerSize())pt)")
    h.isReading = false; h.rebuild()

    h.caret(at: rule); h.pump(0.3)
    h.isReading = true; h.rebuild()
    expectEqual(overlays(), 1, "reading: the rule under the caret is drawn")
    h.caret(at: bold + 3); h.pump(0.3)
    expect(markerSize() < 1, "reading: the caret's line hides them too (\(markerSize())pt)")
    expect(!tv.isEditable, "reading: the text view isn't editable")
    h.type("x\n"); h.key("\t", 48); h.pump()
    expectEqual(h.text, note, "reading: keys don't change the note")

    h.isReading = false; h.rebuild()
    h.caret(at: rule); h.pump(0.3)
    expectEqual(overlays(), 0, "editing: the rule under the caret shows its source")
    expect(tv.isEditable, "editing: typing works again")
}

/// Moving the caret while reading doesn't restyle anything, so leaving reading
/// mode must resync which line the caret is on: moving back onto the line the
/// caret was on before reading still reveals it, and the line the caret left
/// hides its markers again.
func editorReadingResyncChecks() {
    let note = "First **one** line\n\nSecond **two** line"
    let first = (note as NSString).range(of: "**one**").location
    let second = (note as NSString).range(of: "**two**").location
    guard let h = EditorHarness(note) else { expect(false, "editor found"); return }
    defer { h.close() }
    let tv = h.textView
    func markerSize(_ at: Int) -> CGFloat {
        (tv.textStorage?.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.pointSize ?? -1
    }

    h.caret(at: first + 3); h.pump(0.3)
    h.isReading = true; h.rebuild()
    h.caret(at: second + 3); h.pump(0.3)
    h.isReading = false; h.rebuild()
    h.caret(at: first + 3); h.pump(0.3)
    expect(markerSize(first) > 5, "back in editing, returning to the first line shows its ** (\(markerSize(first))pt)")
    expect(markerSize(second) < 1, "and the second line hides its ** again (\(markerSize(second))pt)")
}

/// In reading mode a checkbox is the one thing a click changes; ⌘Z takes it
/// back, and the text view is read-only again after both.
func editorReadingCheckboxChecks() {
    var text = "- [ ] task"
    let view = MarkdownEditorView(text: Binding(get: { text }, set: { text = $0 }), isReading: true)
    let coordinator = view.makeCoordinator()
    let textView = NSTextView()
    textView.allowsUndo = true
    textView.isEditable = false            // as makeNSView sets it up for reading
    textView.delegate = coordinator
    textView.string = text
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = textView
    coordinator.textView = textView
    coordinator.sync(with: view)

    expect(coordinator.handleClick(at: 2), "reading: a checkbox click is handled")
    expectEqual(text, "- [x] task", "and saved to the note")
    expect(!textView.isEditable, "read-only again after the toggle")
    expect(textView.undoManager?.canUndo == true, "the toggle registered an undo")
    textView.undoManager?.undo()
    expectEqual(textView.string, "- [ ] task", "⌘Z takes it back while reading")
    expectEqual(text, "- [ ] task", "and the note follows")
    expect(!textView.isEditable, "read-only again after the undo")
}

/// Switching mid-composition commits the composed text first. Switching keeps
/// the line at the top of the view there, although the lines above it change
/// height (a table under the caret is source rows in editing, a grid in reading).
func editorReadingSwitchChecks() {
    guard let h = EditorHarness("first line\nsecond line") else { expect(false, "editor found"); return }
    h.caret(at: 6)
    h.textView.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    h.textView.didChangeText()                 // an input method reports each step, so the note follows
    h.pump(0.05)
    h.isReading = true; h.rebuild()
    expect(!h.textView.hasMarkedText(), "switching commits the composition")
    expectEqual(h.text, "first 한line\nsecond line", "and the note holds the committed text")
    h.close()

    let rows = (0..<30).map { "| r\($0) | v |" }.joined(separator: "\n")
    let body = (0..<300).map { "Line \($0) with **bold**" }.joined(separator: "\n")
    let note = "| a | b |\n|---|---|\n" + rows + "\n\n" + body
    guard let s = EditorHarness(note, cursorOffset: 3) else { expect(false, "editor found"); return }
    defer { s.close() }
    s.pump(0.4)
    s.scrollToTop(of: (note as NSString).range(of: "Line 150 ").location)
    let before = s.topLineOffset
    expect(before != nil, "a line is at the top")
    s.isReading = true; s.rebuild()
    expectEqual(s.topLineOffset, before, "reading: the same line stays at the top")
    s.isReading = false; s.rebuild()
    expectEqual(s.topLineOffset, before, "editing again: still the same line")
}

/// One editor serves every tab, so a tab switch can change the note and the mode
/// in a single update. The new note must not inherit the old note's scroll
/// anchor: the view ends up where it would for the same switch without a mode
/// change, not at the offset the previous note had at its top.
func editorReadingTabSwitchChecks() {
    let first = (0..<300).map { "First note line \($0)" }.joined(separator: "\n")
    let rows = (0..<30).map { "| r\($0) | v |" }.joined(separator: "\n")
    let second = "| a | b |\n|---|---|\n" + rows + "\n\n"
        + (0..<300).map { "Second note line \($0)" }.joined(separator: "\n")
    guard let h = EditorHarness(first) else { expect(false, "editor found"); return }
    defer { h.close() }
    h.pump(0.4)
    let target = (first as NSString).range(of: "First note line 150").location

    h.scrollToTop(of: target)
    h.text = second; h.rebuild()
    let control = h.topLineOffset

    h.text = first; h.rebuild()
    h.scrollToTop(of: target)
    h.text = second; h.isReading = true; h.rebuild()
    expectEqual(h.topLineOffset, control, "a tab switch into reading scrolls like one without a mode change")
}

/// A checkbox click doesn't move the caret, so ticking one in a long note must
/// leave the view where it is rather than scrolling back to the caret.
func editorCheckboxScrollChecks() {
    let body = (0..<300).map { "Line \($0) with text" }.joined(separator: "\n")
    let note = body + "\n- [ ] task\n" + (0..<20).map { "Tail \($0)" }.joined(separator: "\n")
    let box = (note as NSString).range(of: "[ ] task").location
    for reading in [true, false] {
        let mode = reading ? "reading" : "editing"
        guard let h = EditorHarness(note) else { expect(false, "editor found"); return }
        defer { h.close() }
        h.pump(0.4)
        h.caret(at: 0)
        h.isReading = reading; h.rebuild()
        h.scrollToTop(of: box)
        let before = h.topLineOffset
        expect(before != nil, "\(mode): a line is at the top")
        guard let c = h.textView.delegate as? MarkdownEditorView.Coordinator else { expect(false, "coordinator"); return }
        expect(c.handleClick(at: box + 1), "\(mode): the click toggles the box")
        h.pump(0.4)
        expect(h.text.contains("- [x] task"), "\(mode): the note holds the ticked box")
        expectEqual(h.topLineOffset, before, "\(mode): the view stays where it was")
    }
}

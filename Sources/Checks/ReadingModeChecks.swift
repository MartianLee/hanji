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

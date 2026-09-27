import Foundation
import AppCore
import MKSearchKit

/// Split view keeps one version of each note: what you type is never replaced by
/// a stale copy from the other pane, and a pane closing itself leaves your
/// buffer alone.
func splitSafetyChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-split-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)); try? fm.removeItem(at: vault) }
    for (n, t) in [("A.md", "a"), ("B.md", "b"), ("C.md", "c")] {
        try? t.write(to: vault.appendingPathComponent(n), atomically: true, encoding: .utf8)
    }
    let s = AppState(defaults: UserDefaults(suiteName: "mk-split-\(UUID().uuidString)")!)
    s.openVault(at: vault)
    func tab(_ pane: Int, _ name: String) -> OpenTab? { s.panes[safe: pane]?.tabs.first { $0.file.name == name } }

    // 1. The other pane closing itself doesn't touch the live buffer.
    s.openNote(relativePath: "A.md"); s.openNote(relativePath: "B.md")
    s.moveTabToSide(tab(0, "B.md")!.id, .right)
    s.focusPane(s.panes[0].id)
    s.activeText = "a + typed"
    try? fm.removeItem(at: vault.appendingPathComponent("B.md"))
    s.reloadTree()
    expectEqual(s.panes.count, 1, "setup: the emptied right pane closed")
    expectEqual(s.selectedFile?.name, "A.md", "A is still the open note")
    expectEqual(s.activeText, "a + typed", "and still holds what was typed")

    // 2. The same note in both panes is one note: edits follow you across.
    s.flushPendingSave()
    s.splitRight()
    expect(s.panes.count == 2, "setup: split")
    expect(tab(0, "A.md")?.id != tab(1, "A.md")?.id, "each pane's tab has its own identity")
    s.activeText = "typed on the right"
    s.focusPane(s.panes[0].id)
    expectEqual(s.activeText, "typed on the right", "the left pane shows the right pane's edit")
    s.activeText = "then on the left"
    s.focusPane(s.panes[1].id)
    expectEqual(s.activeText, "then on the left", "and back")
    s.togglePin(tab(1, "A.md")!.id)
    expect(tab(0, "A.md")?.isPinned == false, "pinning one pane's tab leaves the other's alone")
    s.togglePin(tab(1, "A.md")!.id)

    // Opening a note that the other pane already has continues from its buffer.
    s.openNote(relativePath: "C.md")
    s.activeText = "c edited"
    s.focusPane(s.panes[0].id)
    s.openNote(relativePath: "C.md")
    expectEqual(s.activeText, "c edited", "opening C in the other pane shows the same text")

    // Moving a tab into a pane that already shows that note doesn't duplicate it.
    s.moveTabToSide(tab(0, "C.md")!.id, .right)
    expectEqual(s.panes.last!.tabs.filter { $0.file.name == "C.md" }.count, 1, "no duplicate note in one pane")
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

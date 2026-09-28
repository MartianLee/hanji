import Foundation
import AppCore
import VaultKit
import MKSearchKit

/// Obsidian-style navigation: opening a note shows it in the current tab and
/// adds to that tab's history; back and forward walk it. A pinned tab, or an
/// explicit "new tab", opens a new tab instead.
func tabHistoryChecks() {
    let vault = FileManager.default.temporaryDirectory.appendingPathComponent("mk-history-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    for (name, text) in [("A", "alpha"), ("B", "beta"), ("C", "gamma"), ("D", "delta")] {
        try? text.write(to: vault.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    }
    defer {
        try? FileManager.default.removeItem(at: SearchIndex.indexFileURL(forVault: vault))
        try? FileManager.default.removeItem(at: vault)
    }
    let s = AppState(defaults: UserDefaults(suiteName: "mk-history-\(UUID().uuidString)")!)
    s.openVault(at: vault)
    func file(_ name: String) -> MarkdownFile { s.files.first { $0.name == "\(name).md" }! }
    func disk(_ name: String) -> String? {
        try? String(contentsOf: vault.appendingPathComponent("\(name).md"), encoding: .utf8)
    }
    expect(!s.canGoBack && !s.canGoForward, "nothing to go back or forward to before a note is open")

    // Opening replaces the note in the current tab.
    s.open(file("A"))
    expectEqual(s.tabs.count, 1, "the first note opens a tab")
    expect(!s.canGoBack, "a fresh tab has no history")
    s.open(file("B"))
    expectEqual(s.tabs.count, 1, "opening another note reuses the tab")
    expectEqual(s.selectedFile?.name, "B.md", "and shows the new note")
    expect(s.canGoBack && !s.canGoForward, "the previous note is one step back")

    // Back and forward.
    s.goBack()
    expectEqual(s.selectedFile?.name, "A.md", "back returns to A")
    expectEqual(s.activeText, "alpha", "with A's text")
    expectEqual(s.tabs.count, 1, "in the same tab")
    expect(!s.canGoBack && s.canGoForward, "then B is one step forward")
    s.goForward()
    expectEqual(s.selectedFile?.name, "B.md", "forward returns to B")
    s.goBack()
    s.open(file("C"))
    expect(!s.canGoForward, "opening a note drops the forward history")
    s.goBack()
    expectEqual(s.selectedFile?.name, "A.md", "back from C is A again")
    s.goBack()
    expectEqual(s.selectedFile?.name, "A.md", "back at the start of history does nothing")

    // Leaving a note saves it; coming back shows the edit.
    s.activeText = "alpha edited"
    s.open(file("B"))
    expectEqual(disk("A"), "alpha edited", "navigating away saved A")
    s.goBack()
    expectEqual(s.activeText, "alpha edited", "and going back shows the edit")

    // The caret comes back to where it was.
    s.caretMoved(to: 7)
    s.open(file("C"))
    expectEqual(s.pendingCursorOffset, 0, "a newly opened note starts at the top")
    s.goBack()
    expectEqual(s.pendingCursorOffset, 7, "going back puts the caret where it was")
    s.caretMoved(to: 999)
    s.goForward(); s.goBack()
    expectEqual(s.pendingCursorOffset, (s.activeText as NSString).length, "a caret past the end is clamped")

    // A note with a conflict waiting on the user can't be navigated away from.
    s.activeText = "mine"
    try? "theirs".write(to: vault.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
    s.reloadTree()
    expect(s.externalConflict != nil, "setup: A has a conflict")
    s.open(file("B"))
    expectEqual(s.selectedFile?.name, "A.md", "a tab with a conflict stays on its note")
    expect(s.notice != nil, "and says why")
    s.notice = nil
    s.resolveConflictKeepingMine()

    // New tabs.
    s.open(file("B"), newTab: true)
    expectEqual(s.tabs.count, 2, "open in new tab adds a tab")
    expectEqual(s.selectedFile?.name, "B.md", "showing B")
    expect(!s.canGoBack, "with its own, empty history")
    s.togglePin(s.activeTabID!)
    s.open(file("C"))
    expectEqual(s.tabs.count, 3, "a pinned tab opens notes in a new tab")
    expectEqual(s.tabs.first { $0.isPinned }?.file.name, "B.md", "and keeps its note")
    expectEqual(s.selectedFile?.name, "C.md", "the new tab is active")

    // A note already open in another tab of the pane: go to that tab.
    let tabsBefore = s.tabs.map(\.id)
    s.open(file("B"))
    expectEqual(s.tabs.map(\.id), tabsBefore, "no second tab for a note that's open")
    expectEqual(s.selectedFile?.name, "B.md", "its tab becomes active")
    expect(s.tabs.first { $0.id == s.activeTabID }?.isPinned == true, "(the pinned one)")
    s.togglePin(s.activeTabID!)
    s.closeTab(s.activeTabID!)

    // History follows a rename and skips a note that was deleted.
    // Tabs now: [A (history …), C]; C's tab: fresh. Build C → D → A history.
    s.switchTab(s.tabs.first { $0.file.name == "C.md" }!.id)
    s.open(file("D"))
    s.open(file("A"))                    // A is open in the other tab → switches there
    expectEqual(s.selectedFile?.name, "A.md", "A's own tab took over")
    s.switchTab(s.tabs.first { $0.file.name == "D.md" }!.id)
    _ = try? s.rename(file("C").url, to: "C2")
    s.goBack()
    expectEqual(s.selectedFile?.name, "C2.md", "history follows a renamed note")
    s.goForward()
    expectEqual(s.selectedFile?.name, "D.md", "forward to D")
    s.open(file("B"))
    s.delete(file("D").url)
    s.goBack()
    expectEqual(s.selectedFile?.name, "C2.md", "back skips a note that was deleted")

    // Split: navigating one pane leaves the other on its note.
    s.splitRight()
    s.open(file("B"))
    expectEqual(s.selectedFile?.name, "B.md", "the right pane shows B")
    expectEqual(s.panes.first?.tabs.first { $0.id == s.panes.first?.activeTabID }?.file.name, "C2.md",
                "the left pane still shows C2")
    s.goBack()
    expectEqual(s.selectedFile?.name, "C2.md", "back in the right pane returns to C2")
}

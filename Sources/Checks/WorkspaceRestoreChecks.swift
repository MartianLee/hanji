import Foundation
import AppCore
import MKSearchKit

/// A vault of notes A.md … E.md, each long enough for any caret below, a
/// defaults suite for its AppStates, and the cleanup of both.
private func restoreFixture(_ tag: String) -> (vault: URL, suite: String, cleanup: () -> Void) {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-\(tag)-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    for name in ["A", "B", "C", "D", "E"] {
        let text = (0..<40).map { "\(name) line \($0)\n" }.joined()
        try? text.write(to: vault.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    }
    let suite = "mk-\(tag)-\(UUID().uuidString)"
    return (vault, suite, {
        try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault))
        try? fm.removeItem(at: vault)
        UserDefaults().removePersistentDomain(forName: suite)
    })
}

/// "A(pin),*B,C(read) | *D": each pane's tabs, `*` on the one it shows.
private func layout(_ s: AppState) -> String {
    s.panes.map { p in
        p.tabs.map { ($0.id == p.activeTabID ? "*" : "") + $0.file.url.deletingPathExtension().lastPathComponent
                     + ($0.isPinned ? "(pin)" : "") + ($0.isReading ? "(read)" : "") }.joined(separator: ",")
    }.joined(separator: " | ")
}

private func tab(_ s: AppState, _ name: String, pane: Int = 0) -> OpenTab? {
    s.panes.indices.contains(pane) ? s.panes[pane].tabs.first { $0.file.name == name } : nil
}

/// Quitting and reopening brings the workspace back: every tab in both panes,
/// in order, pins and reading mode, which tab each pane showed and which pane
/// was active, and each note's caret and top line.
func workspaceRestoreChecks() {
    let (vault, suite, cleanup) = restoreFixture("restore")
    defer { cleanup() }
    func fresh() -> AppState { AppState(defaults: UserDefaults(suiteName: suite)!) }

    // Each `do` is one run of the app: its AppState (with its vault watcher and
    // its pending save) is gone before the next one starts, as after a quit.
    do {
        let s = fresh()
        s.openVault(at: vault)
        for n in ["A", "B", "C", "D"] { s.openNote(relativePath: "\(n).md", newTab: true) }
        s.togglePin(tab(s, "A.md")!.id)
        s.switchTab(tab(s, "B.md")!.id); s.caretMoved(to: 120); s.viewportMoved(top: 100)
        s.switchTab(tab(s, "C.md")!.id); s.toggleReading(s.activeTabID!); s.viewportMoved(top: 50)
        s.switchTab(tab(s, "D.md")!.id); s.moveTabToSide(s.activeTabID!, .right)
        s.caretMoved(to: 30); s.viewportMoved(top: 20)
        s.focusPane(s.panes[0].id)
        s.switchTab(tab(s, "B.md")!.id)
        expectEqual(layout(s), "A(pin),*B,C(read) | *D", "setup")
        _ = s.saveAllForClose()
    }
    do {
        let r = fresh()
        r.openVault(at: vault)
        expectEqual(layout(r), "A(pin),*B,C(read) | *D", "every tab comes back, in its pane and place")
        expectEqual(r.activePaneID, r.panes.first?.id, "the left pane is the active one again")
        expectEqual(r.selectedFile?.name, "B.md", "showing the note it showed")
        expectEqual(r.activeText, (0..<40).map { "B line \($0)\n" }.joined(), "with its text")
        expectEqual(r.pendingCursorOffset, 120, "the caret goes back where it was")
        expectEqual(r.pendingJumpTopLine, 100, "and the line that was at the top goes back there")
        expectEqual(tab(r, "D.md", pane: 1)?.position, NotePosition(caret: 30, top: 20),
                    "the other pane's note remembers its place for its editor")
        r.switchTab(tab(r, "C.md")!.id)
        expectEqual(r.pendingJumpTopLine, 50, "a background tab comes back at its top line too")
        expect(r.isActiveTabReading, "still in reading mode")
        _ = r.saveAllForClose()
    }

    // Notes deleted meanwhile drop out; a pane's shown tab passes to its neighbour.
    try? FileManager.default.removeItem(at: vault.appendingPathComponent("C.md"))
    try? FileManager.default.removeItem(at: vault.appendingPathComponent("D.md"))
    do {
        let gone = fresh()
        gone.openVault(at: vault)
        expectEqual(layout(gone), "A(pin),*B", "missing notes are dropped, and a pane left empty goes")
        gone.splitRight()
        _ = gone.saveAllForClose()
    }

    // One note in both panes is one buffer, as when it was opened that way.
    do {
        let both = fresh()
        both.openVault(at: vault)
        expectEqual(layout(both), "A(pin),*B | *B", "the same note in both panes")
        expect(tab(both, "B.md")?.buffer === tab(both, "B.md", pane: 1)?.buffer, "shares one buffer")

        // Changes are saved a moment after they settle, not only on quit.
        both.openNote(relativePath: "E.md", newTab: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    }
    do {
        let later = fresh()
        later.openVault(at: vault)
        expectEqual(layout(later), "A(pin),*B | B,*E", "a new tab is remembered without a quit")
    }

    // The test hook opens a vault as it is on disk, with no tabs.
    let bare = fresh()
    bare.openVault(at: vault, restoringWorkspace: false)
    expectEqual(layout(bare), "", "opening without restoring starts with no tabs")
}

/// A vault last opened by a build that only remembered pinned tabs: those still
/// come back, once, until the workspace is stored.
func workspaceRestoreLegacyPinsChecks() {
    let (vault, suite, cleanup) = restoreFixture("restore-legacy")
    defer { cleanup() }
    let d = UserDefaults(suiteName: suite)!
    let s = AppState(defaults: d)
    s.openVault(at: vault)
    for n in ["A", "B", "C"] { s.openNote(relativePath: "\(n).md", newTab: true) }
    s.togglePin(tab(s, "C.md")!.id)
    _ = s.saveAllForClose()
    d.removeObject(forKey: "io.hanji.workspace.\(vault.standardizedFileURL.path)")   // as an older build left it
    let r = AppState(defaults: d)
    r.openVault(at: vault)
    expectEqual(layout(r), "*C(pin)", "the pinned tabs come back")
}

/// Each tab remembers where its note was left, and showing the tab goes back
/// there; a note that starts showing in a tab starts fresh.
func tabPositionChecks() {
    let (vault, suite, cleanup) = restoreFixture("tabpos")
    defer { cleanup() }
    let s = AppState(defaults: UserDefaults(suiteName: suite)!)
    s.openVault(at: vault)
    s.openNote(relativePath: "A.md", newTab: true)
    s.caretMoved(to: 40); s.viewportMoved(top: 30)
    s.openNote(relativePath: "B.md", newTab: true)
    expectEqual(s.pendingCursorOffset, 0, "a newly opened note starts at its top")
    expectEqual(s.pendingJumpTopLine, nil, "with no line to scroll to")
    s.caretMoved(to: 10); s.viewportMoved(top: 12)
    s.switchTab(tab(s, "A.md")!.id)
    expectEqual(s.pendingCursorOffset, 40, "back on A: its caret")
    expectEqual(s.pendingJumpTopLine, 30, "and its top line")

    s.openNote(relativePath: "C.md")                        // in place, in A's tab
    expectEqual(s.pendingCursorOffset, 0, "a note opened in place starts at its top")
    expectEqual(s.pendingJumpTopLine, nil, "not at the line A had at the top")
    s.goBack()
    expectEqual(s.pendingCursorOffset, 40, "Back puts the caret where it was")
    expectEqual(s.pendingJumpTopLine, nil, "and just brings it into view")

    s.openNote(relativePath: "B.md")                        // B's tab comes forward
    expectEqual(s.pendingJumpTopLine, 12, "setup: B's own top line")
    s.pendingCursorOffset = 5                               // a search hit, set right after
    expectEqual(s.pendingJumpTopLine, nil, "a jump set after opening a note drops the note's old placement")
    s.reveal(offset: 9)
    expect(s.pendingJumpToTop && s.pendingCursorOffset == 9, "an outline click still puts its line at the top")

    // A pane scrolled without being focused remembers that, without moving the
    // active pane's focus.
    s.splitRight()
    let leftTab = s.panes[0].activeTabID!
    var seen: [Int] = []
    let token = s.focusOffset.sink { seen.append($0) }
    defer { token.cancel() }
    let before = seen.last
    s.viewportMoved(top: 77, inTab: leftTab)
    expectEqual(s.panes[0].tabs.first { $0.id == leftTab }?.position.top, 77, "the inactive pane's top line is kept")
    expectEqual(seen.last, before, "and the active pane's focus doesn't move")
    expectEqual(s.panes[1].tabs.first?.position.top, 12, "a split's new pane starts where the note was")
}

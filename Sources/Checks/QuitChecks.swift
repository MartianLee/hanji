import Foundation
import AppCore

/// Quitting or switching vaults must first put every edit on disk — including
/// one still waiting on the autosave debounce or in flight on the save queue —
/// and name whatever it couldn't, instead of dropping it.
func quitChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-quit-\(UUID().uuidString)")
    let other = fm.temporaryDirectory.appendingPathComponent("hanji-quit-other-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    try? fm.createDirectory(at: other, withIntermediateDirectories: true)
    let a = root.appendingPathComponent("A.md")
    try? "a".write(to: a, atomically: true, encoding: .utf8)
    try? "b".write(to: root.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
    func lock(_ on: Bool) { try? fm.setAttributes([.immutable: on], ofItemAtPath: a.path) }
    defer { lock(false); try? fm.removeItem(at: root); try? fm.removeItem(at: other) }
    func disk() -> String? { try? String(contentsOf: a, encoding: .utf8) }
    func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    let s = AppState(defaults: UserDefaults(suiteName: "mk-quit-\(UUID().uuidString)")!, autosaveInterval: 0.05)
    s.openVault(at: root)
    s.open(s.files.first { $0.name == "A.md" }!, newTab: true)

    // Typed just before ⌘Q, debounce not yet fired.
    s.activeText = "typed right before quit"
    expectEqual(s.saveAllForClose(), [], "everything could be saved")
    expectEqual(disk(), "typed right before quit", "the pending edit is on disk before quitting")

    // An autosave that fails while in flight is still caught.
    lock(true)
    s.activeText = "can't be written"
    pump(0.12)   // let the debounced autosave start
    expectEqual(s.saveAllForClose(), ["A.md"], "a note that couldn't be saved is named")
    expect(s.isDirty, "and is still dirty")
    s.notice = nil
    lock(false)
    expectEqual(s.saveAllForClose(), [], "once writable, closing saves it")
    expectEqual(disk(), "can't be written", "with the latest text")

    // A pending conflict blocks too, including in a background tab.
    s.activeText = "mine"
    try? "theirs".write(to: a, atomically: true, encoding: .utf8)
    s.reloadTree()
    s.open(s.files.first { $0.name == "B.md" }!, newTab: true)
    expectEqual(s.saveAllForClose(), ["A.md"], "a background tab in conflict is named")
    expectEqual(disk(), "theirs", "and its disk version isn't overwritten")

    // Switching vaults with work that can't be saved stays put and says why.
    s.openVault(at: other)
    expectEqual(s.vaultRoot?.standardizedFileURL, root.standardizedFileURL, "the vault switch is refused")
    expect(s.tabs.contains { $0.file.name == "A.md" }, "the conflicted tab is still open")
    expect(s.notice?.message.contains("A.md") == true, "and the user is told which note needs attention")
}

import Foundation
import AppCore

/// A tab waiting on the "changed on disk" banner holds two versions the user
/// hasn't chosen between. Closing it must neither drop the edits nor write them
/// over the version on disk — it asks the user to resolve the conflict first.
func conflictCloseChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-conflictclose-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let a = root.appendingPathComponent("A.md")
    try? "v1".write(to: a, atomically: true, encoding: .utf8)
    try? "b".write(to: root.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
    func disk() -> String? { try? String(contentsOf: a, encoding: .utf8) }

    let s = AppState(defaults: UserDefaults(suiteName: "mk-cc-\(UUID().uuidString)")!)
    s.openVault(at: root)
    s.open(s.files.first { $0.name == "A.md" }!)
    let aID = s.activeTabID!
    s.activeText = "mine"
    try? "theirs".write(to: a, atomically: true, encoding: .utf8)
    s.reloadTree()
    expectEqual(s.externalConflict, "theirs", "setup: A is in conflict")

    // The active tab.
    s.closeTab(aID)
    expectEqual(s.activeTabID, aID, "a conflicted tab isn't closed")
    expectEqual(s.activeText, "mine", "its edits are kept")
    expect(s.notice?.message.contains("A.md") == true, "the user is told to resolve the conflict first")
    s.notice = nil

    // The same tab in the background still carries both versions.
    s.open(s.files.first { $0.name == "B.md" }!)
    s.closeTab(aID)
    expectEqual(disk(), "theirs", "closing it in the background doesn't overwrite the disk version")
    expect(s.tabs.contains { $0.id == aID }, "and it stays open")
    expect(s.notice != nil, "with the same explanation")
}

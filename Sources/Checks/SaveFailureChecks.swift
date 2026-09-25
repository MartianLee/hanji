import Foundation
import AppCore

/// A save that fails must leave the note dirty, tell the user, and never let
/// the buffer be thrown away as if it had been saved.
func saveFailureChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-savefail-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("A.md")
    try? "disk".write(to: note, atomically: true, encoding: .utf8)
    func lock(_ on: Bool) { try? fm.setAttributes([.immutable: on], ofItemAtPath: note.path) }
    defer { lock(false); try? fm.removeItem(at: root) }
    func disk() -> String? { try? String(contentsOf: note, encoding: .utf8) }
    func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    let s = AppState(defaults: UserDefaults(suiteName: "mk-sf-\(UUID().uuidString)")!, autosaveInterval: 0.05)
    s.openVault(at: root)
    s.open(s.files.first { $0.name == "A.md" }!)
    lock(true)

    // ⌘S / flush
    s.activeText = "edit 1"
    expect(!s.flushPendingSave(), "flush reports that the save didn't happen")
    expect(s.isDirty, "a failed flush leaves the note dirty")
    expectEqual(disk(), "disk", "nothing half-written")
    expect(s.notice?.message.contains("A.md") == true, "the user is told which note didn't save")
    s.notice = nil

    // Closing a tab whose save fails keeps it open with the edits.
    let id = s.activeTabID!
    s.closeTab(id)
    expectEqual(s.activeTabID, id, "the tab stays open when its edits can't be saved")
    expectEqual(s.activeText, "edit 1", "and the edits are still there")
    s.notice = nil

    // Background autosave
    s.activeText = "edit 2"
    pump(0.5)
    expect(s.isDirty, "a failed autosave doesn't mark the note clean")
    expect(s.notice != nil, "a failed autosave is reported")
    s.notice = nil

    // Once the note is writable again, the next save goes through.
    lock(false)
    expect(s.flushPendingSave(), "flush succeeds again")
    expect(!s.isDirty, "and the note is clean")
    expectEqual(disk(), "edit 2", "with the latest text on disk")
}

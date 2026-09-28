import Foundation
import AppCore
import VaultKit
import MKSearchKit

private func vault(_ tag: String, _ files: [(String, String)]) -> URL {
    let fm = FileManager.default
    let v = fm.temporaryDirectory.appendingPathComponent("mk-\(tag)-\(UUID().uuidString)")
    try? fm.createDirectory(at: v, withIntermediateDirectories: true)
    for (n, t) in files { try? t.write(to: v.appendingPathComponent(n), atomically: true, encoding: .utf8) }
    return v
}
private func cleanup(_ v: URL) {
    try? FileManager.default.removeItem(at: SearchIndex.indexFileURL(forVault: v))
    try? FileManager.default.removeItem(at: v)
}
private func pumpUntil(_ timeout: Double, _ done: () -> Bool) {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}

/// A reload while an autosave is still in flight must not decide the note is
/// clean and replace what was typed with the old disk text.
func autosaveRaceChecks() {
    let v = vault("race", [("A.md", "disk")])
    let a = v.appendingPathComponent("A.md")
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: a.path); cleanup(v) }
    let s = AppState(defaults: UserDefaults(suiteName: "mk-race-\(UUID().uuidString)")!, autosaveInterval: 0.05)
    s.openVault(at: v)
    s.openNote(relativePath: "A.md", newTab: true)
    try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: a.path)
    s.activeText = "typed"
    pumpUntil(1) { !s.isDirty }          // the autosave fired and optimistically marked it clean
    s.reloadTree()                       // a watcher fire lands before the failure is reported
    expectEqual(s.activeText, "typed", "the typing survives a reload during a failing autosave")
    pumpUntil(1) { s.isDirty }
    expect(s.isDirty, "and is dirty again once the failure is reported")
}

/// The conflict banner always offers the version that's on disk now.
func conflictLatestChecks() {
    let v = vault("latest", [("A.md", "v0")])
    defer { cleanup(v) }
    let a = v.appendingPathComponent("A.md")
    let s = AppState(defaults: UserDefaults(suiteName: "mk-latest-\(UUID().uuidString)")!)
    s.openVault(at: v)
    s.openNote(relativePath: "A.md", newTab: true)
    s.activeText = "mine"
    try? "v1".write(to: a, atomically: true, encoding: .utf8); s.reloadTree()
    try? "v2".write(to: a, atomically: true, encoding: .utf8); s.reloadTree()
    expectEqual(s.externalConflict, "v2", "a later change on disk updates the conflict's version")
    s.resolveConflictReloadingDisk()
    expectEqual(s.activeText, "v2", "Reload from disk takes the latest version")
}

/// File-name and folder edge cases.
func fileEdgeChecks() {
    let fm = FileManager.default
    let v = vault("edge", [("A.md", "a")])
    defer { cleanup(v) }
    try? fm.createDirectory(at: v.appendingPathComponent("Folder.md"), withIntermediateDirectories: true)
    let s = AppState(defaults: UserDefaults(suiteName: "mk-edge-\(UUID().uuidString)")!)
    s.openVault(at: v)
    expect(!s.files.contains { $0.name == "Folder.md" }, "a folder named X.md isn't a note")

    // A long (but legal) name must stay saveable: the temp file can't be longer.
    let long = String(repeating: "n", count: 240)
    s.openNote(relativePath: "A.md", newTab: true)
    let renamed = try? s.rename(v.appendingPathComponent("A.md"), to: long)
    expect(renamed != nil, "setup: a 240-character name is allowed")
    s.activeText = "saved under a long name"
    expect(s.flushPendingSave(), "a note with a long name saves")
    expectEqual(try? String(contentsOf: v.appendingPathComponent(long + ".md"), encoding: .utf8),
                "saved under a long name", "with its text on disk")

    // Undoing "New folder" doesn't bin what was added to it since.
    let folder = s.newFolder(name: "F")!
    try? "from sync".write(to: folder.appendingPathComponent("External.md"), atomically: true, encoding: .utf8)
    s.undoLastFileOperation()
    expect(fm.fileExists(atPath: folder.appendingPathComponent("External.md").path),
           "a folder that has gained notes isn't trashed by undo")
    expect(s.notice != nil, "and the user is told why")
}

/// A save never writes over a change it hasn't seen: if the file on disk no
/// longer holds the version the note last saw, the save stops and the conflict
/// banner comes up instead — whether the watcher has noticed yet or not.
func saveChecksDiskFirstChecks() {
    let v = vault("inflight", [("A.md", "disk"), ("B.md", "b")])
    let a = v.appendingPathComponent("A.md")
    defer { cleanup(v) }
    let s = AppState(defaults: UserDefaults(suiteName: "mk-inflight-\(UUID().uuidString)")!, autosaveInterval: 0.05)
    s.openVault(at: v)
    s.openNote(relativePath: "A.md", newTab: true)
    s.activeText = "mine"
    try? "theirs".write(to: a, atomically: true, encoding: .utf8)   // before any watcher fire
    pumpUntil(1) { s.externalConflict != nil }
    expectEqual(try? String(contentsOf: a, encoding: .utf8), "theirs", "the autosave didn't write over it")
    expectEqual(s.externalConflict, "theirs", "the conflict banner offers it")
    expect(s.isDirty, "and my edit is still unsaved, not lost")

    // Same for an explicit save (⌘S, switching notes).
    s.resolveConflictReloadingDisk()
    s.activeText = "mine again"
    try? "theirs again".write(to: a, atomically: true, encoding: .utf8)
    expect(!s.flushPendingSave(), "⌘S doesn't write over an unseen change")
    expectEqual(try? String(contentsOf: a, encoding: .utf8), "theirs again", "which survives")
    expectEqual(s.externalConflict, "theirs again", "and is offered in the banner")
}

/// Watchers come and go (every vault switch) while files are changing; one being
/// released mid-event must not crash (the runtime traps a strong reference taken
/// to an object that's being deallocated).
func watcherChurnChecks() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("mk-churn-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    var fired = 0
    for round in 0..<60 {
        var watcher: VaultWatcher? = VaultWatcher(root: dir, debounce: 0.01) { fired += 1 }
        for i in 0..<5 {
            try? "\(round)-\(i)".write(to: dir.appendingPathComponent("f\(i).md"), atomically: true, encoding: .utf8)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        watcher = nil                                   // released while events are in flight
        _ = watcher
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    expect(true, "no crash releasing watchers mid-event (\(fired) notifications)")
}

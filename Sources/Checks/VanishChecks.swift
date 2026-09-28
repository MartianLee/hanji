import Foundation
import AppCore

/// A note can disappear from under an open tab: a git checkout, a sync client,
/// a folder rename, an undo. Unsaved edits must survive every one of those.
func vanishChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-vanish-\(UUID().uuidString)")
    try? fm.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func put(_ rel: String, _ text: String) {
        try? text.write(to: root.appendingPathComponent(rel), atomically: true, encoding: .utf8)
    }
    func read(_ rel: String) -> String? { try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) }
    func exists(_ rel: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(rel).path) }
    put("A.md", "a"); put("Folder/Inner.md", "inner"); put("Gone.md", "gone")

    let s = AppState(defaults: UserDefaults(suiteName: "mk-vanish-\(UUID().uuidString)")!)
    s.openVault(at: root)

    // 1. Deleted outside Hanji while it has unsaved edits: kept, flagged, not recreated.
    s.open(s.files.first { $0.name == "A.md" }!, newTab: true)
    s.activeText = "unsaved in A"
    try? fm.removeItem(at: root.appendingPathComponent("A.md"))
    s.reloadTree()
    expectEqual(s.selectedFile?.name, "A.md", "a dirty note whose file vanished stays open")
    expectEqual(s.activeText, "unsaved in A", "with its edits")
    expect(s.missingOnDisk, "and is flagged as missing on disk")
    s.flushPendingSave()
    expect(!exists("A.md"), "saving doesn't silently recreate a file someone deleted")
    expectEqual(s.saveAllForClose(), ["A.md"], "quitting names it as unsaved")
    s.restoreMissingNote()
    expectEqual(read("A.md"), "unsaved in A", "Save again writes it back")
    expect(!s.missingOnDisk && !s.isDirty, "and clears the flag")

    // 2. It comes back on its own (e.g. checking the branch out again): flag clears.
    s.activeText = "edit before checkout"
    try? fm.removeItem(at: root.appendingPathComponent("A.md"))
    s.reloadTree()
    expect(s.missingOnDisk, "missing again")
    put("A.md", "unsaved in A")
    s.reloadTree()
    expect(!s.missingOnDisk, "the flag clears when the file reappears")
    expectEqual(s.activeText, "edit before checkout", "edits still there")
    s.flushPendingSave()

    // 3. Close without saving discards on request.
    s.activeText = "throw me away"
    try? fm.removeItem(at: root.appendingPathComponent("A.md"))
    s.reloadTree()
    s.closeMissingNote()
    expect(!s.tabs.contains { $0.file.name == "A.md" }, "Close without saving closes it")
    expect(!exists("A.md"), "without recreating the file")

    // 4. Renaming a folder carries its open notes along.
    s.open(s.files.first { $0.name == "Inner.md" }!, newTab: true)
    s.activeText = "unsaved in Inner"
    let renamed = try? s.rename(root.appendingPathComponent("Folder"), to: "Renamed")
    expect(renamed != nil, "folder renamed")
    expectEqual(s.selectedFile?.name, "Inner.md", "the open note inside is still open")
    expectEqual(s.activeText, "unsaved in Inner", "with its edits")
    s.flushPendingSave()
    expectEqual(read("Renamed/Inner.md"), "unsaved in Inner", "and saves to its new path")
    expect(!exists("Folder"), "the old folder isn't recreated")

    // 5. Undoing that rename carries it back.
    s.undoLastFileOperation()
    s.activeText = "after undo"
    s.flushPendingSave()
    expectEqual(read("Folder/Inner.md"), "after undo", "the tab followed the undo back")
    expect(!exists("Renamed"), "nothing left at the renamed path")

    // 6. Deleting a note from Hanji saves its last edits into the Trash copy.
    s.open(s.files.first { $0.name == "Gone.md" }!, newTab: true)
    s.activeText = "last words"
    s.delete(root.appendingPathComponent("Gone.md"))
    expect(!s.tabs.contains { $0.file.name == "Gone.md" }, "its tab closes")
    if case .trashed(_, let trashed)? = s.fileOperations.last {
        expectEqual((try? String(contentsOf: trashed, encoding: .utf8)), "last words", "the Trash copy has the edits")
        try? fm.removeItem(at: trashed)
    } else { expect(false, "delete recorded a trash operation") }
}

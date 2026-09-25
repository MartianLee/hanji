import Foundation
import AppCore

/// Undoing a vault-wide replace restores only files that still hold exactly
/// what the replace wrote. Anything edited, moved or deleted since is left
/// alone — an undo must never destroy newer work or resurrect a deleted note.
func replaceUndoChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-rundo-\(UUID().uuidString)")
    let other = fm.temporaryDirectory.appendingPathComponent("hanji-rundo2-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    try? fm.createDirectory(at: other, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root); try? fm.removeItem(at: other) }
    func put(_ name: String, _ text: String, in dir: URL? = nil) {
        try? text.write(to: (dir ?? root).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func read(_ name: String, in dir: URL? = nil) -> String? {
        try? String(contentsOf: (dir ?? root).appendingPathComponent(name), encoding: .utf8)
    }
    put("a.md", "old a"); put("b.md", "old b"); put("c.md", "old c")

    let s = AppState(defaults: UserDefaults(suiteName: "mk-rundo-\(UUID().uuidString)")!)
    s.openVault(at: root)
    _ = s.replaceInVault(find: "old", with: "new", caseSensitive: true)
    put("b.md", "new b, then edited by hand")
    try? fm.removeItem(at: root.appendingPathComponent("c.md"))

    s.undoLastFileOperation()
    expectEqual(read("a.md"), "old a", "an untouched file is restored")
    expectEqual(read("b.md"), "new b, then edited by hand", "a file edited since keeps the newer edit")
    expect(!fm.fileExists(atPath: root.appendingPathComponent("c.md").path), "a file deleted since isn't recreated")
    expect(s.notice?.message.contains("b.md") == true, "the user is told which files were left alone")
    s.notice = nil

    // The undo history belongs to one vault.
    put("x.md", "old x", in: other)
    _ = s.replaceInVault(find: "old", with: "new", caseSensitive: true)
    s.openVault(at: other)
    expect(!s.canUndoFileOperation, "switching vaults clears the undo history")
    s.undoLastFileOperation()
    expectEqual(read("a.md"), "new a", "so an undo can't reach back into the previous vault")

    // Bounded, so replace batches (which hold full file texts) can't pile up forever.
    for _ in 0..<150 { _ = s.newFolder() }
    expect(s.fileOperations.count <= 100, "the undo history is capped")
}

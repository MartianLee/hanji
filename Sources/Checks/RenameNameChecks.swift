import Foundation
import VaultKit

/// A rename changes a name, never a location: a new name can't smuggle in a
/// path, and one that only changes letter case must work on macOS's
/// case-insensitive disks.
func renameNameChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-rename-\(UUID().uuidString)")
    try? fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let vault = Vault(root: root)
    let note = root.appendingPathComponent("sub/note.md")
    try? "x".write(to: note, atomically: true, encoding: .utf8)

    for bad in ["../escaped", "a/b", "..", ".", ".hidden", "/abs"] {
        var threw = false
        do { _ = try vault.rename(note, to: bad) } catch { threw = true }
        expect(threw, "rename to \"\(bad)\" is refused")
    }
    expect(fm.fileExists(atPath: note.path), "the note stayed where it was")
    expect(!fm.fileExists(atPath: root.appendingPathComponent("escaped.md").path), "nothing escaped the folder")

    // Case-only rename.
    let renamed = try? vault.rename(note, to: "Note")
    expectEqual(renamed?.lastPathComponent, "Note.md", "a case-only rename succeeds")
    let names = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("sub").path)) ?? []
    expectEqual(names.filter { $0.lowercased() == "note.md" }, ["Note.md"], "and the new casing is on disk")
}

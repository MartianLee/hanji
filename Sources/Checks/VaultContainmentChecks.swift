import Foundation
import AppCore

/// Paths handed to the plugin-facing note API come from vault content — a
/// periodic-notes `folder`, a template path — so a shared vault must not be able
/// to reach outside itself through them.
func vaultContainmentChecks() {
    let fm = FileManager.default
    let parent = fm.temporaryDirectory.appendingPathComponent("hanji-contain-\(UUID().uuidString)")
    let root = parent.appendingPathComponent("vault")
    let outside = parent.appendingPathComponent("outside")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: parent) }
    try? "secret".write(to: outside.appendingPathComponent("private.md"), atomically: true, encoding: .utf8)
    try? "inside".write(to: root.appendingPathComponent("ok.md"), atomically: true, encoding: .utf8)

    let state = AppState(defaults: UserDefaults(suiteName: "mk-contain-\(UUID().uuidString)")!)
    state.openVault(at: root)

    state.createNote(relativePath: "../outside/deep/pwned.md", text: "x", cursorOffset: nil)
    expect(!fm.fileExists(atPath: outside.appendingPathComponent("deep/pwned.md").path),
           "createNote refuses a path that climbs out of the vault")
    expect(!fm.fileExists(atPath: outside.appendingPathComponent("deep").path),
           "createNote doesn't even create the folder outside the vault")
    state.createNote(relativePath: "/tmp/../\(outside.path)/abs.md", text: "x", cursorOffset: nil)
    expect(!fm.fileExists(atPath: outside.appendingPathComponent("abs.md").path),
           "an absolute-looking path stays under the vault")

    expectEqual(state.readNote(relativePath: "../outside/private.md"), nil,
                "readNote refuses to read outside the vault")
    expect(!state.noteExists(relativePath: "../outside/private.md"),
           "noteExists doesn't probe outside the vault")

    // Ordinary nested paths — including a harmless `..` that stays inside — still work.
    expectEqual(state.readNote(relativePath: "ok.md"), "inside", "plain path still reads")
    expectEqual(state.readNote(relativePath: "sub/../ok.md"), "inside", "`..` that stays inside is fine")
    state.createNote(relativePath: "Daily/2026-09-25.md", text: "d", cursorOffset: nil)
    expect(state.noteExists(relativePath: "Daily/2026-09-25.md"), "nested create still works")
}

/// Creating a note over an existing one (Templater's save panel lets the user
/// confirm "Replace") keeps the old note recoverable in the Trash.
func createNoteOverwriteChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-overwrite-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let note = root.appendingPathComponent("x.md")
    try? "old".write(to: note, atomically: true, encoding: .utf8)

    let state = AppState(defaults: UserDefaults(suiteName: "mk-ow-\(UUID().uuidString)")!)
    state.openVault(at: root)
    state.createNote(relativePath: "x.md", text: "new", cursorOffset: nil)
    expectEqual(try? String(contentsOf: note, encoding: .utf8), "new", "the new note is written")
    guard case .trashed(_, let trashed)? = state.fileOperations.last else {
        expect(false, "the replaced note went to the Trash"); return
    }
    expectEqual(try? String(contentsOf: trashed, encoding: .utf8), "old", "with its old text")
    state.undoLastFileOperation()
    expectEqual(try? String(contentsOf: note, encoding: .utf8), "old", "and ⌥⌘Z brings it back")
    try? fm.removeItem(at: trashed)
}

import Foundation
import AppCore

func appStateChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-appstate-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try? "# A\nx".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

    let state = AppState(defaults: UserDefaults(suiteName: "mk-as-\(UUID().uuidString)")!)
    state.openVault(at: root)
    expectEqual(state.files.count, 1, "openVault loads files")
    expectEqual(state.index.notes.first?.title ?? "", "A", "openVault builds index")

    state.open(state.files[0], newTab: true)
    expectEqual(state.activeText, "# A\nx", "open loads active text")

    state.activeText = "changed"
    state.save()
    let onDisk = (try? String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8)) ?? ""
    expectEqual(onDisk, "changed", "save persists to disk")
}

func appRecentsChecks() {
    let fm = FileManager.default
    let suite = "mk-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let a = fm.temporaryDirectory.appendingPathComponent("vault-a-\(UUID().uuidString)")
    let b = fm.temporaryDirectory.appendingPathComponent("vault-b-\(UUID().uuidString)")
    try? fm.createDirectory(at: a, withIntermediateDirectories: true)
    try? fm.createDirectory(at: b, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }

    let s1 = AppState(defaults: defaults)
    s1.openVault(at: a)
    s1.openVault(at: b)
    s1.openVault(at: a)          // re-open a → moves to front, no duplicate
    expectEqual(s1.recentVaults.count, 2, "dedupe keeps two vaults")
    expectEqual(s1.recentVaults.first?.standardizedFileURL, a.standardizedFileURL, "most recent first")

    // Persisted across instances.
    let s2 = AppState(defaults: defaults)
    expectEqual(s2.recentVaults.first?.standardizedFileURL, a.standardizedFileURL, "recents persist + reload")

    // Cap at 8: open 10 distinct vaults, keep only the 8 most recent (last opened first).
    let capSuite = "mk-cap-\(UUID().uuidString)"
    let capState = AppState(defaults: UserDefaults(suiteName: capSuite)!)
    defer { UserDefaults(suiteName: capSuite)!.removePersistentDomain(forName: capSuite) }
    var capDirs: [URL] = []
    for i in 0..<10 {
        let v = fm.temporaryDirectory.appendingPathComponent("vault-cap-\(i)-\(UUID().uuidString)")
        try? fm.createDirectory(at: v, withIntermediateDirectories: true)
        capDirs.append(v)
        capState.openVault(at: v)
    }
    defer { capDirs.forEach { try? fm.removeItem(at: $0) } }
    expectEqual(capState.recentVaults.count, 8, "recents cap at 8")
    expectEqual(capState.recentVaults.first?.standardizedFileURL, capDirs.last?.standardizedFileURL, "last opened is first")

    s2.removeRecent(a)
    expectEqual(s2.recentVaults.count, 1, "removeRecent drops one")
    s2.clearRecents()
    expect(s2.recentVaults.isEmpty, "clearRecents empties")
}

func appCreateNoteChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mk-create-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let state = AppState(defaults: UserDefaults(suiteName: "mk-c-\(UUID().uuidString)")!)
    state.openVault(at: root)
    expect(!state.noteExists(relativePath: "Daily/2026-06-09.md"), "note absent before create")
    state.createNote(relativePath: "Daily/2026-06-09.md", text: "# Hi", cursorOffset: 3)
    expect(state.noteExists(relativePath: "Daily/2026-06-09.md"), "note exists after create (folder auto-made)")
    expectEqual(state.readNote(relativePath: "Daily/2026-06-09.md"), "# Hi", "content written")
    expectEqual(state.pendingCursorOffset, 3, "pendingCursorOffset set")
    expect(state.files.contains { $0.name == "2026-06-09.md" }, "file list refreshed")

    state.openNote(relativePath: "Daily/2026-06-09.md", newTab: true)
    expectEqual(state.selectedFile?.name, "2026-06-09.md", "openNote selects the file")
    expectEqual(state.activeText, "# Hi", "openNote loads text")
}

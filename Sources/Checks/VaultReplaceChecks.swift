import Foundation
import AppCore

func vaultReplaceChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-replace-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func write(_ name: String, _ text: String) {
        try? text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func read(_ name: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
    write("a.md", "alpha TODO beta TODO")
    write("b.md", "nothing here")
    write("c.md", "todo lowercase, TODO upper")

    let state = AppState(defaults: UserDefaults(suiteName: "mk-rep-\(UUID().uuidString)")!)
    state.openVault(at: root)

    // Preview reports what would change without touching disk.
    let preview = state.previewReplaceInVault(find: "TODO", caseSensitive: true)
    expectEqual(preview.reduce(0) { $0 + $1.count }, 3, "preview counts every occurrence")
    expectEqual(preview.count, 2, "preview lists only the files that match")
    expectEqual(read("a.md"), "alpha TODO beta TODO", "preview leaves disk untouched")

    let summary = state.replaceInVault(find: "TODO", with: "DONE", caseSensitive: true)
    expectEqual(summary.occurrences, 3, "replaces every occurrence")
    expectEqual(summary.files, 2, "rewrites only the files that matched")
    expectEqual(read("a.md"), "alpha DONE beta DONE", "matches replaced")
    expectEqual(read("c.md"), "todo lowercase, DONE upper", "case-sensitive leaves other casings alone")
    expectEqual(read("b.md"), "nothing here", "non-matching file untouched")

    // The whole batch is one undo step — ⌥⌘Z must not leave the vault half-replaced.
    state.undoLastFileOperation()
    expectEqual(read("a.md"), "alpha TODO beta TODO", "undo restores the first file")
    expectEqual(read("c.md"), "todo lowercase, TODO upper", "undo restores the second file")

    let insensitive = state.replaceInVault(find: "todo", with: "X", caseSensitive: false)
    expectEqual(insensitive.occurrences, 4, "case-insensitive matches every casing")
    state.undoLastFileOperation()
    expectEqual(read("c.md"), "todo lowercase, TODO upper", "undo after a case-insensitive run")

    // An empty needle must do nothing at all — including leaving the undo stack alone,
    // so a stray ⌥⌘Z afterwards doesn't revert some unrelated earlier operation.
    let undoDepthBefore = state.canUndoFileOperation
    let nothing = state.replaceInVault(find: "", with: "x", caseSensitive: true)
    expectEqual(nothing.occurrences, 0, "empty needle replaces nothing")
    expectEqual(state.canUndoFileOperation, undoDepthBefore, "no-op records no undo entry")

    // An open tab must show the replacement, not overwrite it on the next autosave.
    state.open(state.files.first { $0.name == "a.md" }!)
    expectEqual(state.activeText, "alpha TODO beta TODO", "open note loaded")
    _ = state.replaceInVault(find: "TODO", with: "DONE", caseSensitive: true)
    expectEqual(state.activeText, "alpha DONE beta DONE", "open tab refreshed from disk")

    // Unsaved edits are flushed first, so they take part in the replace instead of
    // being clobbered by it.
    state.activeText = "alpha DONE beta DONE PENDING"
    _ = state.replaceInVault(find: "PENDING", with: "SETTLED", caseSensitive: true)
    expectEqual(read("a.md"), "alpha DONE beta DONE SETTLED", "unsaved buffer flushed before replacing")
    expectEqual(state.activeText, "alpha DONE beta DONE SETTLED", "open tab shows the replacement")
}

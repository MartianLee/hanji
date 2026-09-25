import Foundation
import AppCore

/// A note Hanji can't decode must never open as an empty buffer: the first
/// keystroke would autosave over the original bytes.
func unreadableNoteChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-unreadable-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    // "한글" in EUC-KR (CP949): not valid UTF-8.
    let eucKR = Data([0xC7, 0xD1, 0xB1, 0xDB, 0x0A])
    let legacy = root.appendingPathComponent("legacy.md")
    try? eucKR.write(to: legacy)
    try? "fine".write(to: root.appendingPathComponent("fine.md"), atomically: true, encoding: .utf8)

    let state = AppState(defaults: UserDefaults(suiteName: "mk-unread-\(UUID().uuidString)")!)
    state.openVault(at: root)
    state.open(state.files.first { $0.name == "fine.md" }!)
    expectEqual(state.activeText, "fine", "a readable note opens")

    state.open(state.files.first { $0.name == "legacy.md" }!)
    expectEqual(state.selectedFile?.name, "fine.md", "an undecodable note doesn't become the open note")
    expectEqual(state.activeText, "fine", "the current buffer is left alone")
    expectEqual(state.activePane?.tabs.count, 1, "no tab is opened for it")
    expect(state.notice?.message.contains("legacy.md") == true, "the user is told which note couldn't open")

    state.activeText = "typed after the failed open"
    state.flushPendingSave()
    expectEqual(try? Data(contentsOf: legacy), eucKR, "the original bytes are never overwritten")
}

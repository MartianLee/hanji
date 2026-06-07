import Foundation
import AppCore

func appStateChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-appstate-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try? "# A\nx".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

    let state = AppState()
    state.openVault(at: root)
    expectEqual(state.files.count, 1, "openVault loads files")
    expectEqual(state.index.notes.first?.title ?? "", "A", "openVault builds index")

    state.open(state.files[0])
    expectEqual(state.activeText, "# A\nx", "open loads active text")

    state.activeText = "changed"
    state.save()
    let onDisk = (try? String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8)) ?? ""
    expectEqual(onDisk, "changed", "save persists to disk")
}

import Foundation
import AppCore
import VaultKit
import MKSearchKit

private func tempVault(_ prefix: String) -> URL {
    let v = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
    return v
}

private func newState(_ vault: URL) -> AppState {
    let s = AppState(defaults: UserDefaults(suiteName: "mk-as-\(UUID().uuidString)")!)
    s.openVault(at: vault)
    return s
}

private func cleanup(_ vault: URL) {
    try? FileManager.default.removeItem(at: SearchIndex.indexFileURL(forVault: vault))
    try? FileManager.default.removeItem(at: vault)
}

func autosaveChecks() {
    let vault = tempVault("mk-autosave")
    defer { cleanup(vault) }
    try? "alpha original".write(to: vault.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
    try? "beta original".write(to: vault.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)

    let s = newState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let b = s.files.first(where: { $0.name == "B.md" }) else { expect(false, "files found"); return }

    s.open(a)
    expectEqual(s.savedText, "alpha original", "baseline captured on open")
    expect(!s.isDirty, "freshly opened note is clean")
    s.activeText = "alpha edited"
    expect(s.isDirty, "edited note is dirty")

    s.flushPendingSave()
    expect(!s.isDirty, "clean after flush")
    let onDisk = try? String(contentsOf: vault.appendingPathComponent("A.md"), encoding: .utf8)
    expectEqual(onDisk, "alpha edited", "flush wrote to disk")

    s.activeText = "alpha edited again"
    s.open(b)
    expectEqual(s.savedText, "beta original", "B baseline loaded")
    let aAfterSwitch = try? String(contentsOf: vault.appendingPathComponent("A.md"), encoding: .utf8)
    expectEqual(aAfterSwitch, "alpha edited again", "switching saved A's edit")

    s.open(a)
    expect(!s.isDirty, "reopened clean")
    s.flushPendingSave()
    expect(!s.isDirty, "still clean after no-op flush")
}

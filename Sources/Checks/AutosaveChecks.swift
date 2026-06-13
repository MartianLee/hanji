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

    // Switching vaults flushes the outgoing edit too (no data loss).
    s.activeText = "alpha edited before vault switch"
    let vault2 = tempVault("mk-autosave2")
    defer { cleanup(vault2) }
    try? "other".write(to: vault2.appendingPathComponent("C.md"), atomically: true, encoding: .utf8)
    s.openVault(at: vault2)
    let aAfterVaultSwitch = try? String(contentsOf: vault.appendingPathComponent("A.md"), encoding: .utf8)
    expectEqual(aAfterVaultSwitch, "alpha edited before vault switch", "switching vaults saved the edit")
}

func conflictChecks() {
    let vault = tempVault("mk-conflict")
    defer { cleanup(vault) }
    let aURL = vault.appendingPathComponent("A.md")
    try? "v1".write(to: aURL, atomically: true, encoding: .utf8)

    let s = newState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }) else { expect(false, "A found"); return }
    s.open(a)

    // Clean buffer + external change → silent reload.
    try? "external v2".write(to: aURL, atomically: true, encoding: .utf8)
    s.reloadTree()
    expect(s.externalConflict == nil, "clean buffer does not raise a conflict")
    expectEqual(s.activeText, "external v2", "clean buffer reloaded from disk")
    expect(!s.isDirty, "reloaded buffer is clean")

    // Our own write does NOT raise a false conflict.
    s.activeText = "my v3"
    s.flushPendingSave()
    s.reloadTree()
    expect(s.externalConflict == nil, "our own save is not a conflict")
    expectEqual(s.activeText, "my v3", "buffer unchanged after own-write reload")

    // Dirty buffer + external change → conflict, autosave paused.
    s.activeText = "my v4 (unsaved)"
    expect(s.isDirty, "dirty before external change")
    try? "external v4".write(to: aURL, atomically: true, encoding: .utf8)
    s.reloadTree()
    expectEqual(s.externalConflict, "external v4", "conflict captured disk version")
    expectEqual(s.activeText, "my v4 (unsaved)", "my edits preserved during conflict")
    s.flushPendingSave()   // paused — must not write
    let duringConflict = try? String(contentsOf: aURL, encoding: .utf8)
    expectEqual(duringConflict, "external v4", "autosave paused during conflict")

    // A second watcher fire mid-conflict must NOT swap the banner's version.
    try? "external v4-newer".write(to: aURL, atomically: true, encoding: .utf8)
    s.reloadTree()
    expectEqual(s.externalConflict, "external v4", "conflict version is stable across re-fires")

    // Resolve: keep mine → my buffer written over disk, conflict cleared.
    s.resolveConflictKeepingMine()
    expect(s.externalConflict == nil, "conflict cleared after keep-mine")
    let kept = try? String(contentsOf: aURL, encoding: .utf8)
    expectEqual(kept, "my v4 (unsaved)", "keep-mine wrote my version to disk")
    expect(!s.isDirty, "clean after keep-mine flush")

    // Resolve: reload from disk → buffer replaced, conflict cleared.
    s.activeText = "my v5 (unsaved)"
    try? "external v5".write(to: aURL, atomically: true, encoding: .utf8)
    s.reloadTree()
    expectEqual(s.externalConflict, "external v5", "second conflict raised")
    s.resolveConflictReloadingDisk()
    expect(s.externalConflict == nil, "conflict cleared after reload")
    expectEqual(s.activeText, "external v5", "reload took the disk version")
    expect(!s.isDirty, "clean after reload")
}

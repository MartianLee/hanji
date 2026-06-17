import Foundation
import AppCore
import VaultKit
import MKSearchKit

private func tabVault() -> URL {
    let v = FileManager.default.temporaryDirectory.appendingPathComponent("mk-tab-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
    try? "alpha".write(to: v.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
    try? "beta".write(to: v.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
    return v
}
private func tabState(_ vault: URL) -> AppState {
    let s = AppState(defaults: UserDefaults(suiteName: "mk-tab-\(UUID().uuidString)")!)
    s.openVault(at: vault)
    return s
}
private func tabCleanup(_ vault: URL) {
    try? FileManager.default.removeItem(at: SearchIndex.indexFileURL(forVault: vault))
    try? FileManager.default.removeItem(at: vault)
}

func tabChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let b = s.files.first(where: { $0.name == "B.md" }) else { expect(false, "files"); return }

    s.open(a)
    expectEqual(s.tabs.count, 1, "one tab after opening A")
    expectEqual(s.selectedFile?.name, "A.md", "A active")
    s.open(b)
    expectEqual(s.tabs.count, 2, "two tabs")
    expectEqual(s.selectedFile?.name, "B.md", "B active")

    s.open(a)
    expectEqual(s.tabs.count, 2, "no duplicate tab")
    expectEqual(s.selectedFile?.name, "A.md", "A re-activated")

    s.activeText = "alpha edited"
    s.switchTab(s.tabs.first(where: { $0.file.name == "B.md" })!.id)
    expectEqual(s.selectedFile?.name, "B.md", "switched to B")
    s.switchTab(s.tabs.first(where: { $0.file.name == "A.md" })!.id)
    expectEqual(s.activeText, "alpha edited", "A's edit preserved across switches")
    expectEqual(try? String(contentsOf: vault.appendingPathComponent("A.md"), encoding: .utf8),
                "alpha edited", "switching flushed A to disk")

    let aID = s.tabs.first(where: { $0.file.name == "A.md" })!.id
    s.closeTab(aID)
    expectEqual(s.tabs.count, 1, "one tab after close")
    expectEqual(s.selectedFile?.name, "B.md", "neighbor B active")
    s.closeTab(s.activeTabID!)
    expect(s.tabs.isEmpty, "no tabs left")
    expect(s.activeTabID == nil && s.selectedFile == nil && s.activeText == "", "cleared active state")

    s.open(a)
    _ = try? s.rename(a.url, to: "Renamed")
    expectEqual(s.tabs.count, 1, "rename keeps a single tab")
    expectEqual(s.selectedFile?.name, "Renamed.md", "active file renamed in place")
    expectEqual(s.tabs.first?.file.name, "Renamed.md", "tab file renamed in place")
}

func paneProxyChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }) else { expect(false, "files"); return }
    expectEqual(s.panes.count, 1, "starts with one pane")
    expect(s.activePaneID != nil, "active pane set")
    s.open(a)
    expectEqual(s.tabs.count, 1, "tabs proxy reflects active pane")
    expectEqual(s.panes.first?.tabs.count, 1, "active pane holds the tab")
    expectEqual(s.activeTabID, s.panes.first?.activeTabID, "activeTabID proxy matches pane")
}

func tabReloadChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let b = s.files.first(where: { $0.name == "B.md" }) else { expect(false, "files"); return }
    s.open(a); s.open(b)   // A inactive (clean, flushed), B active

    // External edit to an inactive, clean tab → silent reload into its snapshot.
    try? "alpha external".write(to: vault.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
    s.reloadTree()
    let aTab = s.tabs.first { $0.file.name == "A.md" }
    expectEqual(aTab?.text, "alpha external", "inactive clean tab reloaded from disk")
    expect(aTab?.externalConflict == nil, "no conflict for clean inactive tab")
    expect(s.externalConflict == nil, "active B unaffected")

    // External edit conflicting with the ACTIVE tab's unsaved buffer → banner.
    s.activeText = "beta unsaved"
    try? "beta external".write(to: vault.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
    s.reloadTree()
    expectEqual(s.externalConflict, "beta external", "active dirty tab raises a conflict")

    // A vanished file closes its tab.
    try? FileManager.default.removeItem(at: vault.appendingPathComponent("A.md"))
    s.reloadTree()
    expect(!s.tabs.contains { $0.file.name == "A.md" }, "vanished file's tab closed")
}

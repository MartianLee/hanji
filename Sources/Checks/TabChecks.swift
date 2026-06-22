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

func tabReorderChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    try? "gamma".write(to: vault.appendingPathComponent("C.md"), atomically: true, encoding: .utf8)
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let b = s.files.first(where: { $0.name == "B.md" }),
          let c = s.files.first(where: { $0.name == "C.md" }) else { expect(false, "files"); return }
    s.open(a); s.open(b); s.open(c)   // order [A,B,C], C active
    let pane = s.panes.first!
    let aID = s.tabs.first(where: { $0.file.name == "A.md" })!.id
    let bID = s.tabs.first(where: { $0.file.name == "B.md" })!.id

    // Move A to the end → [B,C,A].
    s.moveTab(aID, before: nil, in: pane)
    expectEqual(pane.tabs.map { $0.file.name }, ["B.md", "C.md", "A.md"], "A moved to the end")

    // Move A before B → [A,B,C].
    s.moveTab(aID, before: bID, in: pane)
    expectEqual(pane.tabs.map { $0.file.name }, ["A.md", "B.md", "C.md"], "A moved before B")

    // No-op cases leave order unchanged.
    s.moveTab(aID, before: aID, in: pane)
    s.moveTab(UUID(), before: bID, in: pane)
    expectEqual(pane.tabs.map { $0.file.name }, ["A.md", "B.md", "C.md"], "no-op reorders unchanged")

    // Reorder never disturbs the active tab or its live buffer.
    expectEqual(s.selectedFile?.name, "C.md", "C still active after reorders")
    expectEqual(s.activeTabID, s.tabs.first(where: { $0.file.name == "C.md" })!.id, "activeTabID unchanged")
}

func paneSplitChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    try? "gamma".write(to: vault.appendingPathComponent("C.md"), atomically: true, encoding: .utf8)
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let c = s.files.first(where: { $0.name == "C.md" }) else { expect(false, "files"); return }

    s.open(a)
    s.splitRight()
    expectEqual(s.panes.count, 2, "split creates a second pane")
    expect(s.isSplit, "isSplit true")
    expectEqual(s.selectedFile?.name, "A.md", "right pane shows the same doc")
    s.splitRight()
    expectEqual(s.panes.count, 2, "second splitRight is a no-op")

    // Open targets the active (right) pane.
    s.open(c)
    expectEqual(s.panes.last?.tabs.count, 2, "C opened in the right pane")
    expectEqual(s.panes.first?.tabs.count, 1, "left pane unchanged")

    // Focus + edit preserved across panes.
    let leftID = s.panes.first!.id
    s.activeText = "right edit"          // edit the right pane's active doc (C)
    s.focusPane(leftID)
    expectEqual(s.selectedFile?.name, "A.md", "focused left pane")
    s.activeText = "left edit"
    s.focusPane(s.panes.last!.id)
    expectEqual(s.activeText, "right edit", "right pane's edit preserved")
    s.focusPane(leftID)
    expectEqual(s.activeText, "left edit", "left pane's edit preserved")

    // Closing the left pane's last tab collapses the split.
    s.closeTab(s.activeTabID!)
    expectEqual(s.panes.count, 1, "closing a pane's last tab removes the pane")
    expect(s.selectedFile?.name == "A.md" || s.selectedFile?.name == "C.md", "remaining pane active")
}

func paneMoveTabChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let b = s.files.first(where: { $0.name == "B.md" }) else { expect(false, "files"); return }

    // Two tabs in one pane; move B to the right → new right pane with B.
    s.open(a); s.open(b)
    let bID = s.tabs.first(where: { $0.file.name == "B.md" })!.id
    s.moveTabToSide(bID, .right)
    expectEqual(s.panes.count, 2, "moving a tab right creates a second pane")
    expectEqual(s.panes.last?.tabs.count, 1, "right pane holds the moved tab")
    expectEqual(s.panes.first?.tabs.count, 1, "left pane keeps the other tab")
    expectEqual(s.selectedFile?.name, "B.md", "moved tab is focused")
    expectEqual(s.activePaneID, s.panes.last?.id, "right pane is active")

    // Dead-end: B already rightmost → move right again is a no-op.
    s.moveTabToSide(bID, .right)
    expectEqual(s.panes.count, 2, "moving the rightmost tab further right is a no-op")

    // Merge into existing neighbour: move B left → right pane emptied → collapse.
    s.moveTabToSide(bID, .left)
    expectEqual(s.panes.count, 1, "moving the lone right tab left collapses the split")
    expectEqual(s.tabs.count, 2, "both tabs back in one pane")
    expect(s.tabs.contains { $0.file.name == "B.md" }, "B merged back into the left pane")

    // Lone tab cannot split into a new pane.
    let vault2 = tabVault()
    defer { tabCleanup(vault2) }
    let s2 = tabState(vault2)
    let a2 = s2.files.first(where: { $0.name == "A.md" })!
    s2.open(a2)
    expect(!s2.canMoveTab(s2.activeTabID!, .right), "canMoveTab false for a lone tab (right)")
    expect(!s2.canMoveTab(s2.activeTabID!, .left), "canMoveTab false for a lone tab (left)")
    s2.moveTabToSide(s2.activeTabID!, .right)
    expectEqual(s2.panes.count, 1, "a lone tab does not split into a new pane")
}

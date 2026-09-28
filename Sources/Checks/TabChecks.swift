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

    s.open(a, newTab: true)
    expectEqual(s.tabs.count, 1, "one tab after opening A")
    expectEqual(s.selectedFile?.name, "A.md", "A active")
    s.open(b, newTab: true)
    expectEqual(s.tabs.count, 2, "two tabs")
    expectEqual(s.selectedFile?.name, "B.md", "B active")

    s.open(a, newTab: true)
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

    s.open(a, newTab: true)
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
    s.open(a, newTab: true)
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
    s.open(a, newTab: true); s.open(b, newTab: true)   // A inactive (clean, flushed), B active

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

/// Mirrors the live "open A, open B, edit B, Move Tab Right" sequence and asserts
/// the moved tab carries its own (edited) buffer while the source pane keeps its
/// own — i.e. the two panes' buffers are not cross-contaminated.
func paneMoveBufferChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let b = s.files.first(where: { $0.name == "B.md" }) else { expect(false, "files"); return }
    s.open(a, newTab: true)                       // tab A active, text "alpha"
    s.open(b, newTab: true)                       // tab B active, text "beta"
    s.activeText = "beta EDITED"    // simulate typing into the live (active) B
    let bID = s.activeTabID!
    s.moveTabToSide(bID, .right)

    expectEqual(s.panes.count, 2, "move creates a second pane")
    let left = s.panes.first!, right = s.panes.last!
    expectEqual(left.tabs.map { $0.file.name }, ["A.md"], "left pane holds only A")
    expectEqual(right.tabs.map { $0.file.name }, ["B.md"], "right pane holds only B")
    expectEqual(left.activeTabID, left.tabs.first?.id, "left active tab = A")
    expectEqual(left.tabs.first?.text, "alpha", "left A buffer intact (not contaminated by B's edit)")
    expectEqual(right.tabs.first?.text, "beta EDITED", "right B buffer carries the live edit")
    expectEqual(s.activePaneID, right.id, "right pane is active")
    expectEqual(s.selectedFile?.name, "B.md", "active doc = B")
    expectEqual(s.activeText, "beta EDITED", "live buffer = B's edit")
}

func tabReorderChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    try? "gamma".write(to: vault.appendingPathComponent("C.md"), atomically: true, encoding: .utf8)
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let b = s.files.first(where: { $0.name == "B.md" }),
          let c = s.files.first(where: { $0.name == "C.md" }) else { expect(false, "files"); return }
    s.open(a, newTab: true); s.open(b, newTab: true); s.open(c, newTab: true)   // order [A,B,C], C active
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

    // A non-active pane reorders just as well, and doing so leaves the focused
    // pane (its active tab and live buffer) completely alone.
    s.activeText = "gamma EDITED"
    s.moveTabToSide(s.activeTabID!, .right)     // C → new right pane; left keeps [A,B]
    let leftPane = s.panes.first!
    s.moveTab(leftPane.tabs[0].id, before: nil, in: leftPane)
    expectEqual(leftPane.tabs.map { $0.file.name }, ["B.md", "A.md"], "non-active pane reorders")
    expectEqual(s.activePaneID, s.panes.last?.id, "focus stays in the right pane")
    expectEqual(s.selectedFile?.name, "C.md", "right pane's active tab untouched")
    expectEqual(s.activeText, "gamma EDITED", "live buffer untouched by a non-active reorder")
}

/// A move always re-hydrates the live working state from the moved tab's snapshot,
/// so whichever tab *was* live must have its buffer written back first — even when
/// that isn't the tab being moved. Two ways to hit it: move a background tab out of
/// the active pane, and move a tab that lives in a non-active pane.
func paneMoveTabLiveBufferChecks() {
    // (a) Background tab in the active pane: C is live and edited, A is the one moved.
    let vault = tabVault()
    defer { tabCleanup(vault) }
    try? "gamma".write(to: vault.appendingPathComponent("C.md"), atomically: true, encoding: .utf8)
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let b = s.files.first(where: { $0.name == "B.md" }),
          let c = s.files.first(where: { $0.name == "C.md" }) else { expect(false, "files"); return }
    s.open(a, newTab: true); s.open(b, newTab: true); s.open(c, newTab: true)           // pane0 [A,B,C], C live
    let aID = s.tabs.first(where: { $0.file.name == "A.md" })!.id
    s.activeText = "gamma EDITED"             // unsaved edit in the live tab C
    s.moveTabToSide(aID, .right)

    let left = s.panes.first!
    expectEqual(left.tabs.first(where: { $0.file.name == "C.md" })?.text, "gamma EDITED",
                "live tab C keeps its unsaved edit when a background tab is moved out")
    expectEqual(try? String(contentsOf: vault.appendingPathComponent("C.md"), encoding: .utf8),
                "gamma EDITED", "moving a tab flushes the live doc to disk")
    s.focusPane(left.id)
    expectEqual(s.activeText, "gamma EDITED", "C's edit is still there after focusing back")

    // (b) The moved tab lives in a non-active pane; the live tab is in the other one.
    let vault2 = tabVault()
    defer { tabCleanup(vault2) }
    let s2 = tabState(vault2)
    guard let a2 = s2.files.first(where: { $0.name == "A.md" }),
          let b2 = s2.files.first(where: { $0.name == "B.md" }) else { expect(false, "files"); return }
    s2.open(a2, newTab: true); s2.open(b2, newTab: true)                  // pane0 [A,B], B live
    s2.moveTabToSide(s2.activeTabID!, .right) // panes [[A],[B]], right pane live with B
    s2.activeText = "beta EDITED"             // unsaved edit in the live (right) B
    let a2ID = s2.panes.first!.tabs.first!.id
    s2.moveTabToSide(a2ID, .right)            // move the left pane's A into the right pane

    expectEqual(s2.panes.count, 1, "emptied left pane collapses")
    expectEqual(s2.panes[0].tabs.first(where: { $0.file.name == "B.md" })?.text, "beta EDITED",
                "live tab B keeps its unsaved edit when a tab from another pane is moved in")
}

func paneSplitChecks() {
    let vault = tabVault()
    defer { tabCleanup(vault) }
    try? "gamma".write(to: vault.appendingPathComponent("C.md"), atomically: true, encoding: .utf8)
    let s = tabState(vault)
    guard let a = s.files.first(where: { $0.name == "A.md" }),
          let c = s.files.first(where: { $0.name == "C.md" }) else { expect(false, "files"); return }

    s.open(a, newTab: true)
    s.splitRight()
    expectEqual(s.panes.count, 2, "split creates a second pane")
    expect(s.isSplit, "isSplit true")
    expectEqual(s.selectedFile?.name, "A.md", "right pane shows the same doc")
    s.splitRight()
    expectEqual(s.panes.count, 2, "second splitRight is a no-op")

    // Open targets the active (right) pane.
    s.open(c, newTab: true)
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
    s.open(a, newTab: true); s.open(b, newTab: true)
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
    s2.open(a2, newTab: true)
    expect(!s2.canMoveTab(s2.activeTabID!, .right), "canMoveTab false for a lone tab (right)")
    expect(!s2.canMoveTab(s2.activeTabID!, .left), "canMoveTab false for a lone tab (left)")
    s2.moveTabToSide(s2.activeTabID!, .right)
    expectEqual(s2.panes.count, 1, "a lone tab does not split into a new pane")

    // Creating a new pane on the *left*: it is inserted before the source pane.
    let vault3 = tabVault()
    defer { tabCleanup(vault3) }
    try? "gamma".write(to: vault3.appendingPathComponent("C.md"), atomically: true, encoding: .utf8)
    let s3 = tabState(vault3)
    guard let a3 = s3.files.first(where: { $0.name == "A.md" }),
          let b3 = s3.files.first(where: { $0.name == "B.md" }),
          let c3 = s3.files.first(where: { $0.name == "C.md" }) else { expect(false, "files"); return }
    s3.open(a3, newTab: true); s3.open(b3, newTab: true)                    // pane0 [A,B], B active
    s3.moveTabToSide(s3.activeTabID!, .left)
    expectEqual(s3.panes.count, 2, "moving a tab left creates a second pane")
    expectEqual(s3.panes.first?.tabs.map { $0.file.name }, ["B.md"], "the new pane is the left one")
    expectEqual(s3.panes.last?.tabs.map { $0.file.name }, ["A.md"], "the source pane stays on the right")
    expectEqual(s3.activePaneID, s3.panes.first?.id, "the new left pane is focused")

    // Merge into an existing neighbour while the source pane survives.
    s3.open(c3, newTab: true)                                 // opens in the active (left) pane → [B,C]
    s3.moveTabToSide(s3.activeTabID!, .right)   // C → right pane, left keeps B
    expectEqual(s3.panes.count, 2, "merging into a neighbour keeps two panes")
    expectEqual(s3.panes.first?.tabs.map { $0.file.name }, ["B.md"], "source pane survives with its other tab")
    expectEqual(s3.panes.last?.tabs.map { $0.file.name }, ["A.md", "C.md"], "moved tab appended to the neighbour")
    expectEqual(s3.panes.first?.activeTabID, s3.panes.first?.tabs.first?.id, "source repoints its active tab to B")
    expectEqual(s3.activePaneID, s3.panes.last?.id, "focus follows the moved tab")
    expectEqual(s3.selectedFile?.name, "C.md", "moved tab is the active doc")
}

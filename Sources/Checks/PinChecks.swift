import Foundation
import AppCore
import MKSearchKit

/// Pinned tabs, as in Obsidian: a pinned tab can't be closed until it's
/// unpinned, and the vault remembers its pinned notes — reopening the vault
/// brings them back, pinned.
func pinChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-pin-\(UUID().uuidString)")
    let other = fm.temporaryDirectory.appendingPathComponent("mk-pin-other-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault.appendingPathComponent("Notes"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: other, withIntermediateDirectories: true)
    defer {
        for v in [vault, other] {
            try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: v)); try? fm.removeItem(at: v)
        }
    }
    for name in ["A.md", "B.md", "C.md", "Notes/D.md"] {
        try? name.write(to: vault.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let suite = "mk-pin-\(UUID().uuidString)"
    let s = AppState(defaults: UserDefaults(suiteName: suite)!)
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    s.openVault(at: vault)
    func open(_ rel: String) { s.openNote(relativePath: rel, newTab: true) }
    func tab(_ name: String) -> OpenTab? { s.panes.flatMap(\.tabs).first { $0.file.name == name } }

    // Pinning, and what it does to closing.
    open("A.md"); open("B.md"); open("C.md")
    s.togglePin(tab("B.md")!.id)
    expect(tab("B.md")?.isPinned == true, "a tab can be pinned")
    s.closeTab(tab("B.md")!.id)
    expect(tab("B.md") != nil, "a pinned tab can't be closed (⌘W, the tab's close button)")
    s.togglePin(tab("B.md")!.id)
    s.closeTab(tab("B.md")!.id)
    expect(tab("B.md") == nil, "unpinned, it closes normally")

    // The vault remembers its pins — in tab order, and only the pinned ones.
    open("Notes/D.md")
    s.togglePin(tab("D.md")!.id)
    s.togglePin(tab("A.md")!.id)
    s.openVault(at: other)
    expect(s.tabs.isEmpty, "another vault starts without them")
    s.openVault(at: vault)
    expectEqual(s.tabs.map(\.file.name), ["A.md", "D.md"], "reopening the vault restores its pinned notes, in tab order")
    expect(s.tabs.allSatisfy(\.isPinned), "still pinned")
    expectEqual(s.selectedFile?.name, "A.md", "the first pinned note is the open one")

    // A pinned note that's renamed stays pinned under its new name.
    _ = try? s.rename(vault.appendingPathComponent("A.md"), to: "Renamed")
    s.openVault(at: other); s.openVault(at: vault)
    expectEqual(s.tabs.map(\.file.name), ["Renamed.md", "D.md"], "a rename carries the pin along")

    // One deleted from Hanji is dropped from the pins.
    s.delete(vault.appendingPathComponent("Renamed.md"))
    s.openVault(at: other); s.openVault(at: vault)
    expectEqual(s.tabs.map(\.file.name), ["D.md"], "a deleted note is no longer restored")
    if case .trashed(_, let trashed)? = s.fileOperations.last { try? fm.removeItem(at: trashed) }

    // The pin travels with the tab to the other pane.
    open("C.md")
    s.moveTabToSide(tab("D.md")!.id, .right)
    expect(s.panes.count == 2 && s.panes[1].tabs.first?.isPinned == true, "moving a pinned tab keeps it pinned")
}

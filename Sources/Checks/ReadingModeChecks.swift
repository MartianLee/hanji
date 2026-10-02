import AppKit
import SwiftUI
import AppCore
import EditorEngine
import MKSearchKit
import VaultKit

/// Reading mode belongs to the tab: it survives navigating in the tab and moving
/// it to the other pane, new tabs start in editing, and a pinned tab brings it
/// back when the vault reopens.
func readingTabChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-read-\(UUID().uuidString)")
    let other = fm.temporaryDirectory.appendingPathComponent("mk-read-other-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    try? fm.createDirectory(at: other, withIntermediateDirectories: true)
    defer {
        for v in [vault, other] {
            try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: v)); try? fm.removeItem(at: v)
        }
    }
    for name in ["A.md", "B.md", "C.md"] {
        try? name.write(to: vault.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let suite = "mk-read-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let s = AppState(defaults: defaults)
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    s.openVault(at: vault)
    func tab(_ name: String) -> OpenTab? { s.panes.flatMap(\.tabs).first { $0.file.name == name } }
    func file(_ name: String) -> MarkdownFile { s.files.first { $0.name == name }! }

    s.openNote(relativePath: "A.md", newTab: true)
    s.openNote(relativePath: "C.md", newTab: true)
    s.toggleReading(tab("A.md")!.id)
    expect(tab("A.md")?.isReading == true, "a tab can be put in reading mode")
    expect(tab("C.md")?.isReading == false, "the other tab stays in editing")
    expect(!s.isActiveTabReading, "the active tab (C) is editing")
    s.switchTab(tab("A.md")!.id)
    expect(s.isActiveTabReading, "the active tab (A) is reading")

    s.open(file("B.md"))                       // a link followed in the same tab
    expect(tab("B.md")?.isReading == true, "following a link keeps the tab reading")
    s.goBack()
    expect(tab("A.md")?.isReading == true, "and so does going back")

    s.openNote(relativePath: "B.md", newTab: true)
    expect(tab("B.md")?.isReading == false, "a new tab opens in editing")

    s.moveTabToSide(tab("A.md")!.id, .right)
    expect(s.panes.count == 2 && s.panes[1].tabs.first?.isReading == true, "moving a tab to the other pane keeps it reading")

    // Remembered for pinned tabs only.
    s.togglePin(tab("A.md")!.id)
    s.togglePin(tab("C.md")!.id)
    s.toggleReading(tab("B.md")!.id)           // reading, but not pinned
    let key = "io.hanji.reading.\(vault.standardizedFileURL.path)"
    expectEqual(defaults.stringArray(forKey: key), ["A.md"], "only pinned reading tabs are stored")
    s.openVault(at: other); s.openVault(at: vault)
    expect(tab("A.md")?.isReading == true, "a pinned reading tab comes back reading")
    expect(tab("C.md")?.isReading == false, "a pinned editing tab comes back editing")

    _ = try? s.rename(vault.appendingPathComponent("A.md"), to: "Renamed")
    s.openVault(at: other); s.openVault(at: vault)
    expect(tab("Renamed.md")?.isReading == true, "a rename carries the mode along")
}

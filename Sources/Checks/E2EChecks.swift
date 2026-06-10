import Foundation
import AppCore
import ExtensionSDK
import MarkdownCore
import PeriodicNotesPlugin
import WordCountPlugin
import MKSearchKit

/// One happy-path end-to-end scenario over the real stack (AppState + Host +
/// plugins + filesystem) — the same object graph the app wires in HanjiApp.
/// Run it after every feature: `swift run Checks E2E` (or `Scripts/e2e.sh`).
///
/// Story: open a vault → daily note from template (⌘P command) → new note in a
/// folder → rename → edit + save → find it via the ⌘O fuzzy logic → delete →
/// external change picked up by the live watcher.
func e2eChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mk-e2e-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    // -- Vault fixture: an Obsidian-style vault with periodic-notes config + template.
    let pluginDir = root.appendingPathComponent(".obsidian/plugins/periodic-notes")
    try? fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: root.appendingPathComponent("Templates"), withIntermediateDirectories: true)
    try? "{ \"daily\": { \"folder\": \"Daily\", \"format\": \"YYYY-MM-DD\", \"template\": \"Templates/Daily\" } }"
        .write(to: pluginDir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
    try? "# <% tp.date.now(\"YYYY-MM-DD\") %> — <% tp.file.title %>\n\n<% tp.file.cursor() %>"
        .write(to: root.appendingPathComponent("Templates/Daily.md"), atomically: true, encoding: .utf8)
    try? "# Welcome\nhello".write(to: root.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)

    // -- App wiring, exactly as HanjiApp does it.
    let appState = AppState(defaults: UserDefaults(suiteName: "mk-e2e-\(UUID().uuidString)")!)
    let pm = PluginManager()
    let host = Host(appState: appState, pluginManager: pm)
    pm.activate([WordCountPlugin(), PeriodicNotesPlugin()], host: host)

    // 1. Open the vault: tree, files, and index are populated.
    appState.openVault(at: root)
    expect(appState.tree.contains { $0.name == "Templates" && $0.isDirectory }, "E2E: tree has Templates folder")
    expect(appState.files.contains { $0.name == "Welcome.md" }, "E2E: flat file list has Welcome.md")

    // 2. ⌘P "Open today's daily note": created from the template and opened, caret pending.
    pm.commands.first(where: { $0.id == "periodic.daily" })?.run()
    let today: String = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }()
    expectEqual(appState.selectedFile?.name, today + ".md", "E2E: daily note opened")
    expect(appState.activeText.hasPrefix("# \(today) — \(today)"), "E2E: template rendered into daily note")
    expect(appState.pendingCursorOffset != nil, "E2E: caret position queued from tp.file.cursor")

    // 3. New folder + new note inside it (file-tree ops).
    guard let projects = appState.newFolder(inFolder: nil, name: "Projects") else {
        expect(false, "E2E: create Projects folder"); return
    }
    expect(appState.tree.contains { $0.name == "Projects" && $0.isDirectory }, "E2E: folder in tree")
    let note = appState.newNote(inFolder: projects)
    expectEqual(note?.lastPathComponent, "Untitled.md", "E2E: new note created in folder")
    expectEqual(appState.selectedFile?.url.standardizedFileURL, note?.standardizedFileURL, "E2E: new note opened")

    // 4. Rename it, then edit + save; the content survives a reopen.
    _ = try? appState.rename(note!, to: "Plan")
    expectEqual(appState.selectedFile?.url.lastPathComponent, "Plan.md", "E2E: rename follows the open note")
    appState.activeText = "# Plan\n- [ ] first step"
    appState.save()
    let onDisk = (try? String(contentsOf: root.appendingPathComponent("Projects/Plan.md"), encoding: .utf8)) ?? ""
    expectEqual(onDisk, "# Plan\n- [ ] first step", "E2E: edits saved to disk")

    // 4b. Global search finds the freshly saved content (sync reindex for determinism).
    try? appState.searchIndex?.reindexAll(vault: root)
    let searchHits = (try? appState.searchIndex?.search("first step")) ?? []
    expectEqual(searchHits.first?.path, "Projects/Plan.md", "E2E: global search finds saved note")
    expect(searchHits.first?.firstMatchOffset != nil, "E2E: search hit carries a caret offset")

    // 4c. Backlinks: a hub note linking [[Plan]] shows up as Plan's backlink.
    try? "허브: [[Plan]] 참고".write(to: root.appendingPathComponent("Hub.md"), atomically: true, encoding: .utf8)
    try? appState.searchIndex?.reindexAll(vault: root)
    let planBacklinks = (try? appState.searchIndex?.backlinks(of: "Projects/Plan.md")) ?? []
    expectEqual(planBacklinks.map(\.sourcePath), ["Hub.md"], "E2E: backlink found via link table")

    // 5. ⌘O quick-switcher logic finds it by fuzzy name.
    let hit = FuzzyFilter.filter("plan", appState.files, key: { $0.name }).first
    expectEqual(hit?.name, "Plan.md", "E2E: fuzzy switcher finds the note")

    // 5b. Drag & drop: move Welcome.md into Projects (intra-vault move).
    _ = try? appState.move(root.appendingPathComponent("Welcome.md"), into: projects)
    expect(fm.fileExists(atPath: root.appendingPathComponent("Projects/Welcome.md").path), "E2E: note moved into folder")

    // 6. Delete the open note → editor cleared, tree updated.
    appState.delete(note!.deletingLastPathComponent().appendingPathComponent("Plan.md"))
    expect(appState.selectedFile == nil, "E2E: deleting open note clears editor")
    expect(!fm.fileExists(atPath: root.appendingPathComponent("Projects/Plan.md").path), "E2E: note gone from vault")

    // 6b. Duplicate a note, then undo the duplication (⌥⌘Z path).
    let dup = appState.duplicate(root.appendingPathComponent("Projects/Welcome.md"))
    expectEqual(dup?.lastPathComponent, "Welcome 1.md", "E2E: duplicate auto-suffixes")
    appState.undoLastFileOperation()
    expect(!fm.fileExists(atPath: dup!.path), "E2E: undo removes the duplicate")

    // 6c. Import an external .md by drag-in (copy; source untouched).
    let inbox = fm.temporaryDirectory.appendingPathComponent("mk-e2e-inbox-\(UUID().uuidString)")
    try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: inbox) }
    let extNote = inbox.appendingPathComponent("Clipped.md")
    try? "# Clipped".write(to: extNote, atomically: true, encoding: .utf8)
    let importedNotes = appState.importNotes([extNote], into: nil)
    expectEqual(importedNotes.first?.lastPathComponent, "Clipped.md", "E2E: external note imported")
    expect(fm.fileExists(atPath: extNote.path), "E2E: import copies, source kept")

    // 7. An external tool drops a file in: the live watcher refreshes the tree.
    try? "# Ext".write(to: root.appendingPathComponent("External.md"), atomically: true, encoding: .utf8)
    let deadline = Date().addingTimeInterval(5)
    while !appState.tree.contains(where: { $0.name == "External.md" }) && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    expect(appState.tree.contains { $0.name == "External.md" }, "E2E: watcher picked up external file")
}

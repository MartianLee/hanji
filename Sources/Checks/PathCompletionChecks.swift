import Foundation
import AppCore
import PeriodicNotesPlugin
import MKSearchKit

/// Folder / template pickers in plugin settings: the vault's paths, ranked as
/// you type.
func pathCompletionChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-pcomp-\(UUID().uuidString)")
    for dir in ["Journal/Daily", "Templates", ".obsidian/plugins"] {
        try? fm.createDirectory(at: vault.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    defer { try? fm.removeItem(at: vault) }
    for note in ["Templates/Daily.md", "Templates/Weekly.md", "Journal/Daily/2026-06-09.md", "Inbox.md"] {
        try? "x".write(to: vault.appendingPathComponent(note), atomically: true, encoding: .utf8)
    }
    let appState = AppState(defaults: UserDefaults(suiteName: "mk-pcomp-\(UUID().uuidString)")!)
    appState.openVault(at: vault)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    let host = Host(appState: appState, pluginManager: PluginManager())

    expectEqual(host.folderPaths(), ["Journal", "Journal/Daily", "Templates"], "every visible folder, nested ones by path")
    expectEqual(host.notePaths(), ["Inbox.md", "Journal/Daily/2026-06-09.md", "Templates/Daily.md", "Templates/Weekly.md"],
                "every note, vault-relative")

    let templates = ["Inbox", "Journal/Daily/2026-06-09", "Templates/Daily", "Templates/Weekly"]
    expectEqual(PathCompletion.suggestions(for: "tdai", in: templates), ["Templates/Daily"], "fuzzy match")
    expectEqual(PathCompletion.suggestions(for: "daily", in: templates).first, "Templates/Daily",
                "a closer match ranks first")
    expectEqual(PathCompletion.suggestions(for: "", in: templates, limit: 2), ["Inbox", "Journal/Daily/2026-06-09"],
                "an empty field lists the first few")
    expectEqual(PathCompletion.suggestions(for: "Templates/Daily", in: templates), [],
                "nothing to suggest once the field holds an exact path")
    expectEqual(PathCompletion.suggestions(for: "zzz", in: templates), [], "no match, no list")
}

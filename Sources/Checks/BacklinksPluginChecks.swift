import Foundation
import Combine
import ExtensionSDK
import AppCore
import MKSearchKit

func metadataQueryingChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-mq-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "# Target\nbody".write(to: vault.appendingPathComponent("Target.md"), atomically: true, encoding: .utf8)
    try? "링크: [[Target]]".write(to: vault.appendingPathComponent("Source.md"), atomically: true, encoding: .utf8)

    let appState = AppState(defaults: UserDefaults(suiteName: "mk-mq-\(UUID().uuidString)")!)
    appState.openVault(at: vault)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    let pm = PluginManager()
    let host = Host(appState: appState, pluginManager: pm)

    // Synchronous reindex so the query is deterministic.
    try? appState.searchIndex?.reindexAll(vault: vault)
    let backs = host.query.backlinks(toNoteAt: "Target.md")
    expectEqual(backs.map(\.sourcePath), ["Source.md"], "SDK query surfaces backlinks")
    expectEqual(backs.first?.sourceTitle, "Source", "SDK backlink carries the title")

    // activeNotePath publishes the vault-relative path of the open note.
    var received: [String?] = []
    let sub = host.editor.activeNotePath.sink { received.append($0) }
    appState.open(appState.files.first(where: { $0.name == "Source.md" })!)
    expect(received.contains("Source.md"), "activeNotePath publishes the open note's relative path")
    sub.cancel()
}

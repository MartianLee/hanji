import Foundation
import Combine
import ExtensionSDK
import AppCore
import MKSearchKit
import BacklinksPlugin

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
    appState.open(appState.files.first(where: { $0.name == "Source.md" })!, newTab: true)
    expect(received.contains("Source.md"), "activeNotePath publishes the open note's relative path")
    sub.cancel()
}

func backlinksPluginChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-bp-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "# Target\nbody".write(to: vault.appendingPathComponent("Target.md"), atomically: true, encoding: .utf8)
    try? "보라 [[Target]] 링크".write(to: vault.appendingPathComponent("Source.md"), atomically: true, encoding: .utf8)

    let appState = AppState(defaults: UserDefaults(suiteName: "mk-bp-\(UUID().uuidString)")!)
    appState.openVault(at: vault)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    let pm = PluginManager()
    let host = Host(appState: appState, pluginManager: pm)
    pm.activate([BacklinksPlugin()], host: host)

    expectEqual(pm.sidebar.count, 1, "backlinks sidebar contribution registered")
    expectEqual(pm.sidebar.first?.title ?? "", "Backlinks", "panel title")
    _ = pm.sidebar.first?.makeView()   // view factory doesn't crash without a window

    // The same query path the view uses returns the linking note.
    try? appState.searchIndex?.reindexAll(vault: vault)
    let backs = host.query.backlinks(toNoteAt: "Target.md")
    expectEqual(backs.first?.sourcePath, "Source.md", "panel's data source finds the backlink")
}

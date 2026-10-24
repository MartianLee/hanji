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

/// The SDK's unlinked-mention query: candidates from the index, offsets from
/// the file, the note itself and linked mentions left out.
func unlinkedMentionQueryChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-um-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "Target is me".write(to: vault.appendingPathComponent("Target.md"), atomically: true, encoding: .utf8)
    try? "---\ntags: [x]\n---\nthe target, and [[Target]]".write(to: vault.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
    try? "한지는 종이".write(to: vault.appendingPathComponent("한지.md"), atomically: true, encoding: .utf8)
    try? "한지는 종이다".write(to: vault.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)

    let appState = AppState(defaults: UserDefaults(suiteName: "mk-um-\(UUID().uuidString)")!)
    appState.openVault(at: vault)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    let host = Host(appState: appState, pluginManager: PluginManager())
    try? appState.searchIndex?.reindexAll(vault: vault)

    let mentions = host.query.unlinkedMentions(ofNoteAt: "Target.md")
    expectEqual(mentions.map(\.sourcePath), ["A.md"], "one unlinked mention, not the note itself")
    expectEqual(mentions.first?.range, 22..<28, "its range is in the file's text (frontmatter included)")
    expectEqual(host.query.unlinkedMentions(ofNoteAt: "한지.md").map(\.sourcePath), ["B.md"], "a two-letter Korean name")
    expect(host.workspace.linkMention(sourcePath: "A.md", range: 22..<28, targetPath: "Target.md"), "the Link action")
    expectEqual(try? String(contentsOf: vault.appendingPathComponent("A.md"), encoding: .utf8),
                "---\ntags: [x]\n---\nthe [[Target|target]], and [[Target]]", "writes the link")
}

import Foundation
import ExtensionSDK
import AppCore
import WordCountPlugin
import BacklinksPlugin
import MKSearchKit

func pluginToggleChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-tg-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "# A".write(to: vault.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

    let suite = "mk-tg-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let appState = AppState(defaults: UserDefaults(suiteName: "mk-tg2-\(UUID().uuidString)")!)
    appState.openVault(at: vault)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    let pm = PluginManager(defaults: defaults)
    let host = Host(appState: appState, pluginManager: pm)
    pm.activate([WordCountPlugin(), BacklinksPlugin()], host: host)

    expectEqual(pm.plugins.map(\.id), ["io.hanji.wordcount", "io.hanji.backlinks"], "roster registered")
    expectEqual(pm.plugins.first?.displayName, "wordcount", "default displayName = last id component")
    expectEqual(pm.statusItems.count, 1, "wordcount status item active")
    expectEqual(pm.sidebar.count, 1, "backlinks sidebar active")
    expect(pm.isEnabled("io.hanji.backlinks"), "enabled by default")

    // Live disable removes exactly that plugin's contributions.
    pm.setEnabled("io.hanji.backlinks", false)
    expectEqual(pm.sidebar.count, 0, "disable removes its sidebar view")
    expectEqual(pm.statusItems.count, 1, "other plugin untouched")
    expect(!pm.isEnabled("io.hanji.backlinks"), "state persisted")

    // Live re-enable restores by re-running activate.
    pm.setEnabled("io.hanji.backlinks", true)
    expectEqual(pm.sidebar.count, 1, "enable restores the sidebar view")

    // Disabled state survives a relaunch: a fresh manager skips activation.
    pm.setEnabled("io.hanji.wordcount", false)
    let pm2 = PluginManager(defaults: defaults)
    let host2 = Host(appState: appState, pluginManager: pm2)
    pm2.activate([WordCountPlugin(), BacklinksPlugin()], host: host2)
    expectEqual(pm2.statusItems.count, 0, "disabled plugin not activated on launch")
    expectEqual(pm2.sidebar.count, 1, "enabled plugin still activates")
}

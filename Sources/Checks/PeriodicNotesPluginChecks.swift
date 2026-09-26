import Foundation
import ExtensionSDK
import AppCore
import PeriodicNotesPlugin

func periodicNotesPluginChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mk-pn-\(UUID().uuidString)")
    let templates = root.appendingPathComponent("Templates")
    try? fm.createDirectory(at: templates, withIntermediateDirectories: true)
    let pluginDir = root.appendingPathComponent(".obsidian/plugins/periodic-notes")
    try? fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try? "{ \"daily\": { \"folder\": \"Daily\", \"format\": \"YYYY-MM-DD\", \"template\": \"Templates/Daily\" } }"
        .write(to: pluginDir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
    try? "# <% tp.file.title %>".write(to: templates.appendingPathComponent("Daily.md"), atomically: true, encoding: .utf8)

    let appState = AppState(defaults: UserDefaults(suiteName: "mk-pn-\(UUID().uuidString)")!)
    appState.openVault(at: root)
    let pm = PluginManager()
    let host = Host(appState: appState, pluginManager: pm)
    pm.activate([PeriodicNotesPlugin()], host: host)

    expectEqual(pm.commands.count, 7, "five period commands + previous/next registered")
    guard let today = pm.commands.first(where: { $0.id == "periodic.daily" }) else {
        expect(false, "daily command missing"); return
    }
    today.run()

    let created = appState.readNote(relativePath: "Daily/" + isoToday() + ".md")
    expect(created != nil, "daily note created from template")
    expectEqual(appState.selectedFile?.name, isoToday() + ".md", "created note is opened")
}

private func isoToday() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date())
}

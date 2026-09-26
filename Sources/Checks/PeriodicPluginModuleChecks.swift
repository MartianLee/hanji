import Foundation
import ExtensionSDK
import AppCore
import PeriodicNotesPlugin
import CalendarPlugin
import MKSearchKit

/// Periodic Notes as a module: its commands, its settings pane and the daily-note
/// service Calendar uses all come and go with the plugin's switch.
func periodicPluginModuleChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-ppm-\(UUID().uuidString)")
    let pluginDir = vault.appendingPathComponent(".obsidian/plugins/periodic-notes")
    try? fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: vault.appendingPathComponent("Daily"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? """
    { "daily": { "folder": "Daily", "format": "YYYY-MM-DD" },
      "weekly": { "enabled": false, "format": "" },
      "quarterly": { "folder": "Q", "format": "YYYY-[Q]Q" } }
    """.write(to: pluginDir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
    for d in ["2026-06-01", "2026-06-09", "2026-06-20"] {
        try? "# \(d)".write(to: vault.appendingPathComponent("Daily/\(d).md"), atomically: true, encoding: .utf8)
    }

    let appState = AppState(defaults: UserDefaults(suiteName: "mk-ppm-\(UUID().uuidString)")!)
    appState.openVault(at: vault)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    let suite = "mk-ppm-pm-\(UUID().uuidString)"
    let pm = PluginManager(defaults: UserDefaults(suiteName: suite)!)
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let host = Host(appState: appState, pluginManager: pm)
    pm.activate([PeriodicNotesPlugin(), CalendarPlugin()], host: host)
    func command(_ id: String) -> Command? { pm.commands.first { $0.id == id } }

    // Commands for every period; a disabled period's command isn't offered.
    for kind in ["daily", "weekly", "monthly", "quarterly", "yearly"] {
        expect(command("periodic.\(kind)") != nil, "\(kind) command registered")
    }
    expect(command("periodic.weekly")?.isAvailable() == false, "a disabled period's command is hidden")
    expect(command("periodic.quarterly")?.isAvailable() == true, "an enabled one is offered")
    command("periodic.quarterly")?.run()
    let quarter = "Q/" + { () -> String in
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        return "\(c.year!)-Q\((c.month! - 1) / 3 + 1)"
    }() + ".md"
    expect(appState.noteExists(relativePath: quarter), "the quarterly command creates this quarter's note")

    // Previous / next from the open periodic note.
    try? "plain".write(to: vault.appendingPathComponent("Ideas.md"), atomically: true, encoding: .utf8)
    appState.reloadTree()
    appState.openNote(relativePath: "Ideas.md")
    expect(command("periodic.next")?.isAvailable() == false, "next isn't offered on an ordinary note")
    appState.openNote(relativePath: "Daily/2026-06-09.md")
    expect(command("periodic.next")?.isAvailable() == true, "next is offered on a daily note")
    command("periodic.next")?.run()
    expectEqual(appState.selectedFile?.name, "2026-06-20.md", "next jumps to the closest later note")
    command("periodic.previous")?.run()
    command("periodic.previous")?.run()
    expectEqual(appState.selectedFile?.name, "2026-06-01.md", "previous jumps back past missing days")

    // A settings pane and the daily-note service while enabled…
    expect(pm.settingsPanes.contains { $0.id == "periodic-notes" }, "Periodic Notes contributes a settings pane")
    _ = pm.settingsPanes.first?.makeView()
    guard let daily = host.services.dailyNotes else { expect(false, "daily-note service provided"); return }
    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
    let june9 = cal.date(from: DateComponents(year: 2026, month: 6, day: 9))!
    let june10 = cal.date(from: DateComponents(year: 2026, month: 6, day: 10))!
    expect(daily.hasDailyNote(on: june9), "the service sees an existing daily note")
    expect(!daily.hasDailyNote(on: june10), "and a missing one")

    // …and none of it once the plugin is switched off.
    pm.setEnabled(PeriodicNotesPlugin.id, false)
    expect(!pm.commands.contains { $0.id.hasPrefix("periodic.") }, "its commands are gone")
    expect(!pm.settingsPanes.contains { $0.id == "periodic-notes" }, "its settings pane is gone")
    expect(host.services.dailyNotes == nil, "its daily-note service is gone, so Calendar can't create notes")
    expectEqual(pm.sidebar.count, 1, "Calendar itself stays")

    pm.setEnabled(PeriodicNotesPlugin.id, true)
    expect(host.services.dailyNotes != nil, "switching it back on restores the service")
}

import Foundation
import TemplateKit

private let utc = TimeZone(identifier: "UTC")!

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
    return cal.date(from: DateComponents(year: y, month: m, day: d))!
}

/// Quarterly/yearly notes, per-period `enabled`, and period arithmetic.
func periodicKindsChecks() {
    let fm = FileManager.default
    let d = day(2026, 6, 9)

    let empty = PeriodicConfig([:])
    expectEqual(empty.notePath(.quarterly, date: d, timeZone: utc), "2026-Q2.md", "default quarterly path")
    expectEqual(empty.notePath(.yearly, date: d, timeZone: utc), "2026.md", "default yearly path")
    expect(PeriodicKind.allCases.allSatisfy { empty.settings(for: $0).enabled }, "every period is on by default")

    let vault = fm.temporaryDirectory.appendingPathComponent("mk-pk-\(UUID().uuidString)")
    let dir = vault.appendingPathComponent(".obsidian/plugins/periodic-notes")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? """
    { "settings": {
        "weekly":    { "enabled": false, "format": "" },
        "quarterly": { "enabled": true, "folder": "Q", "format": "YYYY-[Q]Q", "template": "T/Quarter" },
        "yearly":    { "folder": "Years", "format": "YYYY" } } }
    """.write(to: dir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
    let cfg = PeriodicConfig.load(vaultRoot: vault)
    expect(!cfg.settings(for: .weekly).enabled, "an explicitly disabled period stays disabled, even with no format")
    expectEqual(cfg.settings(for: .weekly).format, "gggg-[W]ww", "and keeps the default format")
    expectEqual(cfg.notePath(.quarterly, date: d, timeZone: utc), "Q/2026-Q2.md", "configured quarterly path")
    expectEqual(cfg.templatePath(.quarterly), "T/Quarter.md", "quarterly template")
    expectEqual(cfg.notePath(.yearly, date: d, timeZone: utc), "Years/2026.md", "configured yearly path")
    expect(cfg.settings(for: .yearly).enabled, "a period without `enabled` is on")

    // Stepping by whole periods.
    func step(_ k: PeriodicKind, _ n: Int) -> String {
        MomentFormat.format(k.adding(n, to: d, timeZone: utc), "YYYY-MM-DD", timeZone: utc)
    }
    expectEqual(step(.daily, 1), "2026-06-10", "next day")
    expectEqual(step(.weekly, -1), "2026-06-02", "previous week")
    expectEqual(step(.monthly, 1), "2026-07-09", "next month")
    expectEqual(step(.quarterly, 1), "2026-09-09", "next quarter")
    expectEqual(step(.yearly, -1), "2025-06-09", "previous year")
}

/// Reading a date back out of a periodic note's name.
func momentParseChecks() {
    func parse(_ s: String, _ f: String) -> String? {
        MomentFormat.parse(s, f, timeZone: utc).map { MomentFormat.format($0, "YYYY-MM-DD", timeZone: utc) }
    }
    expectEqual(parse("2026-06-09", "YYYY-MM-DD"), "2026-06-09", "daily")
    expectEqual(parse("2026-W24", "gggg-[W]ww"), "2026-06-08", "ISO week → its Monday")
    expectEqual(parse("2021-W01", "gggg-[W]ww"), "2021-01-04", "ISO week 1 can start in January")
    expectEqual(parse("2026-Q2", "YYYY-[Q]Q"), "2026-04-01", "quarter → its first day")
    expectEqual(parse("2026", "YYYY"), "2026-01-01", "year")
    expectEqual(parse("June 2026", "MMMM YYYY"), "2026-06-01", "month name")
    expectEqual(parse("Tue, 9 Jun 26", "ddd, D MMM YY"), "2026-06-09", "short names and 2-digit year")
    expectEqual(parse("2026-06-09 notes", "YYYY-MM-DD"), nil, "extra text doesn't match")
    expectEqual(parse("2026-13-01", "YYYY-MM-DD"), nil, "an impossible date doesn't match")
    expectEqual(parse("2026-02-30", "YYYY-MM-DD"), nil, "nor does a day the month doesn't have")
}

/// Which periodic note is open, and the closest existing one before/after it.
func periodicNavigationChecks() {
    let cfg = PeriodicConfig([
        .daily: PeriodicSettings(folder: "Daily", format: "YYYY-MM-DD", template: nil),
        .monthly: PeriodicSettings(folder: "", format: "YYYY-MM", template: nil),
    ])
    let existing: Set<String> = ["Daily/2026-06-01.md", "Daily/2026-06-09.md", "Daily/2026-06-20.md", "2026-05.md"]
    let exists: (String) -> Bool = { existing.contains($0) }

    expectEqual(cfg.kind(ofNotePath: "Daily/2026-06-09.md", timeZone: utc), .daily, "a daily note is recognised")
    expectEqual(cfg.kind(ofNotePath: "2026-06.md", timeZone: utc), .monthly, "so is a monthly one")
    expectEqual(cfg.kind(ofNotePath: "Daily/Ideas.md", timeZone: utc), nil, "an ordinary note isn't periodic")
    expectEqual(cfg.kind(ofNotePath: "2026-06-09.md", timeZone: utc), nil, "the daily format outside its folder isn't a daily note")

    expectEqual(cfg.adjacentNote(from: "Daily/2026-06-09.md", direction: 1, exists: exists, timeZone: utc),
                "Daily/2026-06-20.md", "next skips the days without a note")
    expectEqual(cfg.adjacentNote(from: "Daily/2026-06-09.md", direction: -1, exists: exists, timeZone: utc),
                "Daily/2026-06-01.md", "previous likewise")
    expectEqual(cfg.adjacentNote(from: "Daily/2026-06-20.md", direction: 1, exists: exists, timeZone: utc),
                nil, "nothing after the last note")
    expectEqual(cfg.adjacentNote(from: "2026-06.md", direction: -1, exists: exists, timeZone: utc),
                "2026-05.md", "monthly navigation")
    expectEqual(cfg.adjacentNote(from: "Daily/Ideas.md", direction: 1, exists: exists, timeZone: utc),
                nil, "not a periodic note: nowhere to go")
}

/// Settings written back to data.json keep everything Hanji doesn't manage.
func periodicSaveChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-ps-\(UUID().uuidString)")
    let dir = vault.appendingPathComponent(".obsidian/plugins/periodic-notes")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    let file = dir.appendingPathComponent("data.json")
    try? """
    { "showGettingStartedBanner": false,
      "settings": { "daily": { "enabled": true, "folder": "Daily", "format": "YYYY-MM-DD", "openAtStartup": true } } }
    """.write(to: file, atomically: true, encoding: .utf8)

    var cfg = PeriodicConfig.load(vaultRoot: vault)
    cfg.set(PeriodicSettings(folder: "Journal", format: "YYYY-MM-DD", template: "Templates/Day.md"), for: .daily)
    cfg.set(PeriodicSettings(folder: "", format: "YYYY", template: nil, enabled: false), for: .yearly)
    expect((try? cfg.save(vaultRoot: vault)) != nil, "saving succeeds")

    let reloaded = PeriodicConfig.load(vaultRoot: vault)
    expectEqual(reloaded.settings(for: .daily).folder, "Journal", "the change round-trips")
    expectEqual(reloaded.templatePath(.daily), "Templates/Day.md", "template round-trips")
    expect(!reloaded.settings(for: .yearly).enabled, "a disabled period round-trips")
    let raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
    expectEqual(raw?["showGettingStartedBanner"] as? Bool, false, "unknown top-level keys are kept")
    let daily = (raw?["settings"] as? [String: Any])?["daily"] as? [String: Any]
    expectEqual(daily?["openAtStartup"] as? Bool, true, "unknown per-period keys are kept")
    expectEqual(daily?["template"] as? String, "Templates/Day", "templates are stored the way Obsidian writes them (no .md)")

    // No config yet: the file is created.
    let fresh = fm.temporaryDirectory.appendingPathComponent("mk-ps2-\(UUID().uuidString)")
    try? fm.createDirectory(at: fresh, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: fresh) }
    var blank = PeriodicConfig.load(vaultRoot: fresh)
    blank.set(PeriodicSettings(folder: "Weeks", format: "gggg-[W]ww", template: nil), for: .weekly)
    expect((try? blank.save(vaultRoot: fresh)) != nil, "saving into a vault without the config creates it")
    expectEqual(PeriodicConfig.load(vaultRoot: fresh).settings(for: .weekly).folder, "Weeks", "and it loads back")
}

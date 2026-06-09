import Foundation
import TemplateKit

func periodicConfigChecks() {
    let utc = TimeZone(identifier: "UTC")!
    var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 9
    var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
    let d = cal.date(from: c)!

    // Defaults when no .obsidian config present.
    let fm = FileManager.default
    let empty = fm.temporaryDirectory.appendingPathComponent("mk-pc-empty-\(UUID().uuidString)")
    try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: empty) }
    let defcfg = PeriodicConfig.load(vaultRoot: empty)
    expectEqual(defcfg.notePath(.daily, date: d, timeZone: utc), "2026-06-09.md", "default daily path (root)")
    expectEqual(defcfg.notePath(.weekly, date: d, timeZone: utc), "2026-W24.md", "default weekly path")
    expectEqual(defcfg.notePath(.monthly, date: d, timeZone: utc), "2026-06.md", "default monthly path")
    expect(defcfg.templatePath(.daily) == nil, "no template by default")

    // Reading an Obsidian periodic-notes data.json.
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-pc-\(UUID().uuidString)")
    let pluginDir = vault.appendingPathComponent(".obsidian/plugins/periodic-notes")
    try? fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    let json = """
    { "daily":   { "folder": "Daily",   "format": "YYYY-MM-DD", "template": "Templates/Daily" },
      "monthly": { "folder": "Journal/Monthly", "format": "YYYY-MM", "template": "Templates/Monthly.md" } }
    """
    try? json.write(to: pluginDir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
    let cfg = PeriodicConfig.load(vaultRoot: vault)
    expectEqual(cfg.notePath(.daily, date: d, timeZone: utc), "Daily/2026-06-09.md", "configured daily path")
    expectEqual(cfg.templatePath(.daily), "Templates/Daily.md", "template gets .md appended")
    expectEqual(cfg.notePath(.monthly, date: d, timeZone: utc), "Journal/Monthly/2026-06.md", "configured monthly path")
    expectEqual(cfg.templatePath(.monthly), "Templates/Monthly.md", "template kept as-is when .md present")
    expectEqual(cfg.notePath(.weekly, date: d, timeZone: utc), "2026-W24.md", "weekly falls back to default")

    // Periodic Notes v1.x nests kinds under "settings"; also exercise trailing-slash folder normalization.
    let v1 = fm.temporaryDirectory.appendingPathComponent("mk-pc-v1-\(UUID().uuidString)")
    let v1dir = v1.appendingPathComponent(".obsidian/plugins/periodic-notes")
    try? fm.createDirectory(at: v1dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: v1) }
    try? "{ \"settings\": { \"weekly\": { \"folder\": \"Weekly/\", \"format\": \"gggg-[W]ww\" } } }"
        .write(to: v1dir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
    let v1cfg = PeriodicConfig.load(vaultRoot: v1)
    expectEqual(v1cfg.notePath(.weekly, date: d, timeZone: utc), "Weekly/2026-W24.md",
                "v1.x settings wrapper + trailing-slash folder normalized")

    // Core daily-notes.json fallback when the periodic-notes plugin config is absent.
    let core = fm.temporaryDirectory.appendingPathComponent("mk-pc-core-\(UUID().uuidString)")
    let coreObsidian = core.appendingPathComponent(".obsidian")
    try? fm.createDirectory(at: coreObsidian, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: core) }
    try? "{ \"folder\": \"Journal\", \"format\": \"YYYY-MM-DD\" }"
        .write(to: coreObsidian.appendingPathComponent("daily-notes.json"), atomically: true, encoding: .utf8)
    let corecfg = PeriodicConfig.load(vaultRoot: core)
    expectEqual(corecfg.notePath(.daily, date: d, timeZone: utc), "Journal/2026-06-09.md", "daily-notes.json fallback")
    expectEqual(corecfg.notePath(.monthly, date: d, timeZone: utc), "2026-06.md", "monthly still default under daily-notes fallback")
}

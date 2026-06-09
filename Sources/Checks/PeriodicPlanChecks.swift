import Foundation
import TemplateKit

func periodicPlanChecks() {
    let utc = TimeZone(identifier: "UTC")!
    var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 9
    var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
    let d = cal.date(from: c)!
    let cfg = PeriodicConfig([.daily: PeriodicSettings(folder: "Daily", format: "YYYY-MM-DD", template: "Templates/Daily.md")])

    // Existing note → .open
    let openAction = cfg.planOpen(.daily, date: d,
                                  exists: { _ in true },
                                  readTemplate: { _ in nil },
                                  now: d, timeZone: utc)
    expectEqual(openAction, .open(path: "Daily/2026-06-09.md"), "existing note → open")

    // Missing note → .create with rendered template + cursor
    let template = "# <% tp.file.title %>\n<% tp.date.now(\"YYYY-MM-DD\") %>\n<% tp.file.cursor() %>"
    let createAction = cfg.planOpen(.daily, date: d,
                                    exists: { _ in false },
                                    readTemplate: { path in path == "Templates/Daily.md" ? template : nil },
                                    now: d, timeZone: utc)
    if case let .create(path, text, cursor) = createAction {
        expectEqual(path, "Daily/2026-06-09.md", "create path")
        expectEqual(text, "# 2026-06-09\n2026-06-09\n", "template rendered (title = filename base)")
        expect(cursor == text.utf16.count, "cursor at end where token was")
    } else {
        expect(false, "missing note should produce .create")
    }

    // Missing note, no template → empty body
    let cfg2 = PeriodicConfig([.daily: PeriodicSettings(folder: "", format: "YYYY-MM-DD", template: nil)])
    let bare = cfg2.planOpen(.daily, date: d, exists: { _ in false }, readTemplate: { _ in nil }, now: d, timeZone: utc)
    expectEqual(bare, .create(path: "2026-06-09.md", text: "", cursor: nil), "no template → empty create")

    // Template path configured but the file is unreadable → create with empty body, not crash.
    let cfg3 = PeriodicConfig([.daily: PeriodicSettings(folder: "Daily", format: "YYYY-MM-DD", template: "Templates/Missing.md")])
    let missing = cfg3.planOpen(.daily, date: d, exists: { _ in false }, readTemplate: { _ in nil }, now: d, timeZone: utc)
    expectEqual(missing, .create(path: "Daily/2026-06-09.md", text: "", cursor: nil), "missing template file → empty create")
}

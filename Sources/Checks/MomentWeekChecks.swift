import Foundation
import TemplateKit

/// moment's week tokens, as Obsidian (Periodic Notes) uses them: `gggg`/`ww` are
/// *locale* weeks (default locale: weeks start on Sunday, week 1 holds Jan 1),
/// `GGGG`/`WW` are ISO weeks. Getting this wrong names weekly notes differently
/// from Obsidian on Sundays and around New Year — duplicates in a shared vault.
func momentWeekChecks() {
    let utc = TimeZone(identifier: "UTC")!
    var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
    func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }
    func f(_ date: Date, _ p: String) -> String { MomentFormat.format(date, p, timeZone: utc) }

    expectEqual(f(d(2026, 9, 27), "gggg-[W]ww"), "2026-W40", "a Sunday starts a new locale week")
    expectEqual(f(d(2026, 9, 26), "gggg-[W]ww"), "2026-W39", "the Saturday before is still the old one")
    expectEqual(f(d(2026, 12, 31), "gggg-[W]ww"), "2027-W01", "the week holding Jan 1 is week 1 of the new year")
    expectEqual(f(d(2026, 6, 9), "gggg-[W]ww"), "2026-W24", "mid-year Tuesday")
    expectEqual(f(d(2026, 9, 27), "GGGG-[W]WW"), "2026-W39", "ISO: that Sunday ends ISO week 39")
    expectEqual(f(d(2027, 1, 1), "GGGG-[W]WW"), "2026-W53", "ISO: Jan 1 2027 is in 2026's week 53")
    expectEqual(f(d(2026, 9, 7), "W w"), "37 37", "unpadded week tokens")
    expectEqual(["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "31st"],
                [1, 2, 3, 4, 11, 12, 13, 21, 22, 31].map { f(d(2026, 1, $0), "Do") }, "ordinal day of month")

    func p(_ s: String, _ pattern: String) -> String? {
        MomentFormat.parse(s, pattern, timeZone: utc).map { f($0, "YYYY-MM-DD") }
    }
    expectEqual(p("2026-W40", "gggg-[W]ww"), "2026-09-27", "a locale week parses to its Sunday")
    expectEqual(p("2027-W01", "gggg-[W]ww"), "2026-12-27", "week 1 can start in December")
    expectEqual(p("2026-W39", "GGGG-[W]WW"), "2026-09-21", "an ISO week parses to its Monday")
    expectEqual(p("September 27th, 2026", "MMMM Do, YYYY"), "2026-09-27", "ordinals parse")
}

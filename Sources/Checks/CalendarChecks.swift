import Foundation
import CalendarPlugin

func calendarGridChecks() {
    var sunCal = Calendar(identifier: .gregorian)
    sunCal.timeZone = TimeZone(identifier: "UTC")!
    sunCal.firstWeekday = 1   // Sunday
    var monCal = sunCal
    monCal.firstWeekday = 2   // Monday

    func date(_ y: Int, _ m: Int, _ d: Int, _ cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // June 2026 starts on a Monday and has 30 days.
    let june = CalendarGrid.weeks(for: date(2026, 6, 15, sunCal), calendar: sunCal)
    expect(june.count == 5, "June 2026 fits 5 rows (Sunday start)")
    expect(june.allSatisfy { $0.count == 7 }, "every row has 7 days")
    expectEqual(june[0][0].inMonth, false, "leading May day padded")
    expectEqual(june[0][1].day, 1, "June 1 in the second cell (Monday)")
    expect(june[0][1].inMonth, "June 1 is in-month")
    expectEqual(june.flatMap { $0 }.filter(\.inMonth).count, 30, "30 in-month days")

    // Monday-start calendar: June 1 lands in the first cell.
    let juneMon = CalendarGrid.weeks(for: date(2026, 6, 15, monCal), calendar: monCal)
    expectEqual(juneMon[0][0].day, 1, "Monday-start puts June 1 first")
    expect(juneMon[0][0].inMonth, "first cell in-month")

    // February 2024: leap year, 29 days.
    let feb = CalendarGrid.weeks(for: date(2024, 2, 10, sunCal), calendar: sunCal)
    expectEqual(feb.flatMap { $0 }.filter(\.inMonth).count, 29, "leap February has 29 days")

    // Month title is locale-aware.
    let title = CalendarGrid.monthTitle(for: date(2026, 6, 15, sunCal), locale: Locale(identifier: "ko_KR"))
    expect(title.contains("2026") && title.contains("6"), "Korean month title has year+month")
}

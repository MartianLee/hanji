import Foundation
import TemplateKit

func momentFormatChecks() {
    let utc = TimeZone(identifier: "UTC")!
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        return cal.date(from: c)!
    }
    let d = date(2026, 6, 9, 14, 5, 7)            // 2026-06-09 is a Tuesday
    expectEqual(MomentFormat.format(d, "YYYY-MM-DD", timeZone: utc), "2026-06-09", "daily format")
    expectEqual(MomentFormat.format(d, "YYYY-MM", timeZone: utc), "2026-06", "monthly format")
    expectEqual(MomentFormat.format(d, "YYYY-MM-DD HH:mm", timeZone: utc), "2026-06-09 14:05", "date+time")
    expectEqual(MomentFormat.format(d, "YY-MM-DD HH:mm:ss", timeZone: utc), "26-06-09 14:05:07", "YY and seconds")
    expectEqual(MomentFormat.format(d, "ddd, MMM D", timeZone: utc), "Tue, Jun 9", "weekday+month names")
    let jan1 = date(2026, 1, 1)                   // Thursday → ISO week 1 of 2026
    expectEqual(MomentFormat.format(jan1, "gggg-[W]ww", timeZone: utc), "2026-W01", "ISO week with literal")
    expectEqual(MomentFormat.format(d, "[Q]Q", timeZone: utc), "Q2", "quarter with literal")
}

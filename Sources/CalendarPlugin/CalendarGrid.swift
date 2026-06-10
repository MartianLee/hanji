import Foundation

/// Pure month-grid math for the calendar panel: 4–6 rows of 7 days, padded
/// with the neighboring months' days (marked `inMonth == false`).
public enum CalendarGrid {
    public struct Day: Equatable {
        public let date: Date
        public let day: Int        // day-of-month number to display
        public let inMonth: Bool
        public init(date: Date, day: Int, inMonth: Bool) {
            self.date = date
            self.day = day
            self.inMonth = inMonth
        }
    }

    public static func weeks(for month: Date, calendar: Calendar) -> [[Day]] {
        let comps = calendar.dateComponents([.year, .month], from: month)
        guard let firstOfMonth = calendar.date(from: comps),
              let dayCount = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count
        else { return [] }

        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)   // 1 = Sunday
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var days: [Day] = []
        for i in 0..<leading {
            guard let d = calendar.date(byAdding: .day, value: -(leading - i), to: firstOfMonth) else { continue }
            days.append(Day(date: d, day: calendar.component(.day, from: d), inMonth: false))
        }
        for n in 0..<dayCount {
            guard let d = calendar.date(byAdding: .day, value: n, to: firstOfMonth) else { continue }
            days.append(Day(date: d, day: n + 1, inMonth: true))
        }
        while days.count % 7 != 0 {
            guard let last = days.last?.date,
                  let d = calendar.date(byAdding: .day, value: 1, to: last) else { break }
            days.append(Day(date: d, day: calendar.component(.day, from: d), inMonth: false))
        }
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }

    public static func monthTitle(for month: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: month)
    }
}

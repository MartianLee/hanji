import Foundation

/// Formats a `Date` using a subset of moment.js tokens. Text inside `[...]` is literal.
/// Supported: YYYY YY · MMMM MMM MM M · DD Do D · dddd ddd · HH mm ss · Q ·
/// gggg ww w (locale weeks) · GGGG WW W (ISO weeks).
/// Weeks follow moment: `gggg`/`ww` are the locale's weeks — moment's default
/// locale (and Obsidian's usual ones) starts them on Sunday, with week 1 the week
/// that holds Jan 1 — while `GGGG`/`WW` are ISO weeks (Monday, week 1 holds the
/// first Thursday). Periodic Notes' default weekly format is `gggg-[W]ww`, so
/// matching moment here is what keeps weekly note names the same as Obsidian's.
/// Month/weekday names are always English (POSIX).
public enum MomentFormat {
    public static func format(_ date: Date, _ pattern: String,
                              timeZone: TimeZone = .current,
                              locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone; cal.locale = locale
        var iso = Calendar(identifier: .iso8601); iso.timeZone = timeZone; iso.locale = locale
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let isoYear = iso.component(.yearForWeekOfYear, from: date)
        let isoWeek = iso.component(.weekOfYear, from: date)
        let local = localeWeekCalendar(timeZone)
        let weekYear = local.component(.yearForWeekOfYear, from: date)
        let week = local.component(.weekOfYear, from: date)
        let quarter = (c.month! - 1) / 3 + 1
        let months = ["January","February","March","April","May","June",
                      "July","August","September","October","November","December"]
        let weekdays = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"] // weekday 1 = Sunday
        func pad(_ n: Int, _ w: Int) -> String { String(format: "%0\(w)d", n) }

        // Longest-first so YYYY matches before YY, MMMM before MMM, etc.
        let tokens: [(String, () -> String)] = [
            ("YYYY", { pad(c.year!, 4) }), ("YY", { pad(c.year! % 100, 2) }),
            ("MMMM", { months[c.month! - 1] }), ("MMM", { String(months[c.month! - 1].prefix(3)) }),
            ("MM", { pad(c.month!, 2) }), ("M", { String(c.month!) }),
            ("DD", { pad(c.day!, 2) }), ("Do", { ordinal(c.day!) }), ("D", { String(c.day!) }),
            ("dddd", { weekdays[c.weekday! - 1] }), ("ddd", { String(weekdays[c.weekday! - 1].prefix(3)) }),
            ("HH", { pad(c.hour!, 2) }), ("mm", { pad(c.minute!, 2) }), ("ss", { pad(c.second!, 2) }),
            ("gggg", { pad(weekYear, 4) }), ("ww", { pad(week, 2) }), ("w", { String(week) }),
            ("GGGG", { pad(isoYear, 4) }), ("WW", { pad(isoWeek, 2) }), ("W", { String(isoWeek) }),
            ("Q", { String(quarter) }),
        ]
        let chars = Array(pattern)
        var out = ""
        var i = 0
        outer: while i < chars.count {
            if chars[i] == "[" {
                var j = i + 1
                while j < chars.count && chars[j] != "]" { out.append(chars[j]); j += 1 }
                i = (j < chars.count) ? j + 1 : j
                continue
            }
            for (tok, make) in tokens where matches(chars, i, tok) {
                out += make(); i += tok.count; continue outer
            }
            out.append(chars[i]); i += 1
        }
        return out
    }

    /// The date `string` names under `pattern` — the inverse of `format`, for
    /// reading a periodic note's date back out of its file name. Fields the
    /// pattern lacks default to the start of the period (an ISO week → its Monday,
    /// a quarter → its first month). nil unless the whole string matches and names
    /// a real date: the result must format back to exactly `string`, which also
    /// rejects rollovers like 2026-02-30.
    public static func parse(_ string: String, _ pattern: String,
                             timeZone: TimeZone = .current) -> Date? {
        let months = ["January","February","March","April","May","June",
                      "July","August","September","October","November","December"]
        let weekdays = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]
        // Same longest-first order as `format`.
        let tokens: [(String, String)] = [
            ("YYYY", #"(\d{4})"#), ("YY", #"(\d{2})"#),
            ("MMMM", "(" + months.joined(separator: "|") + ")"),
            ("MMM", "(" + months.map { String($0.prefix(3)) }.joined(separator: "|") + ")"),
            ("MM", #"(\d{2})"#), ("M", #"(\d{1,2})"#), ("DD", #"(\d{2})"#),
            ("Do", #"(\d{1,2})(?:st|nd|rd|th)"#), ("D", #"(\d{1,2})"#),
            ("dddd", "(" + weekdays.joined(separator: "|") + ")"),
            ("ddd", "(" + weekdays.map { String($0.prefix(3)) }.joined(separator: "|") + ")"),
            ("HH", #"(\d{2})"#), ("mm", #"(\d{2})"#), ("ss", #"(\d{2})"#),
            ("gggg", #"(\d{4})"#), ("ww", #"(\d{2})"#), ("w", #"(\d{1,2})"#),
            ("GGGG", #"(\d{4})"#), ("WW", #"(\d{2})"#), ("W", #"(\d{1,2})"#), ("Q", "([1-4])"),
        ]
        let chars = Array(pattern)
        var regex = "^"
        var fields: [String] = []
        var i = 0
        outer: while i < chars.count {
            if chars[i] == "[" {
                var j = i + 1
                var literal = ""
                while j < chars.count && chars[j] != "]" { literal.append(chars[j]); j += 1 }
                regex += NSRegularExpression.escapedPattern(for: literal)
                i = (j < chars.count) ? j + 1 : j
                continue
            }
            for (tok, group) in tokens where matches(chars, i, tok) {
                regex += group; fields.append(tok); i += tok.count; continue outer
            }
            regex += NSRegularExpression.escapedPattern(for: String(chars[i])); i += 1
        }
        regex += "$"
        guard let re = try? NSRegularExpression(pattern: regex),
              let m = re.firstMatch(in: string, range: NSRange(string.startIndex..., in: string))
        else { return nil }
        var values: [String: String] = [:]
        for (k, tok) in fields.enumerated() {
            guard let r = Range(m.range(at: k + 1), in: string) else { return nil }
            values[tok] = String(string[r])
        }
        func int(_ tok: String) -> Int? { values[tok].flatMap { Int($0) } }

        let date: Date?
        if let isoYear = int("GGGG"), let week = int("WW") ?? int("W") {
            var iso = Calendar(identifier: .iso8601); iso.timeZone = timeZone
            date = iso.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: isoYear))
        } else if let weekYear = int("gggg"), let week = int("ww") ?? int("w") {
            // A locale week stands for its first day, Sunday.
            date = localeWeekCalendar(timeZone)
                .date(from: DateComponents(weekday: 1, weekOfYear: week, yearForWeekOfYear: weekYear))
        } else {
            var c = DateComponents()
            // moment's two-digit years: 00–68 → 20xx, 69–99 → 19xx.
            c.year = int("YYYY") ?? int("YY").map { $0 < 69 ? 2000 + $0 : 1900 + $0 }
            guard c.year != nil else { return nil }
            c.month = int("MM") ?? int("M")
                ?? values["MMMM"].flatMap { months.firstIndex(of: $0) }.map { $0 + 1 }
                ?? values["MMM"].flatMap { v in months.firstIndex { $0.hasPrefix(v) } }.map { $0 + 1 }
                ?? int("Q").map { ($0 - 1) * 3 + 1 }
                ?? 1
            c.day = int("DD") ?? int("Do") ?? int("D") ?? 1
            c.hour = int("HH") ?? 0; c.minute = int("mm") ?? 0; c.second = int("ss") ?? 0
            var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
            date = cal.date(from: c)
        }
        guard let date, format(date, pattern, timeZone: timeZone) == string else { return nil }
        return date
    }

    /// moment's default locale weeks: Sunday first, week 1 holds Jan 1.
    private static func localeWeekCalendar(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 1
        cal.minimumDaysInFirstWeek = 1
        return cal
    }

    /// 1st 2nd 3rd 4th … 11th 12th 13th … 21st 22nd.
    private static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    private static func matches(_ chars: [Character], _ i: Int, _ tok: String) -> Bool {
        let t = Array(tok)
        guard i + t.count <= chars.count else { return false }
        for k in 0..<t.count where chars[i + k] != t[k] { return false }
        return true
    }
}

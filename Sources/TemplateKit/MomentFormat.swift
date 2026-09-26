import Foundation

/// Formats a `Date` using a subset of moment.js tokens. Text inside `[...]` is literal.
/// Supported: YYYY YY · MMMM MMM MM M · DD D · dddd ddd · HH mm ss · gggg ww (ISO) · Q.
/// Note: month/weekday names are always English (POSIX); `locale` only affects the
/// underlying calendar's numeric computations, not localized names. Use lowercase `ww`
/// for the ISO week — `W` (uppercase) is not a token and passes through literally.
public enum MomentFormat {
    public static func format(_ date: Date, _ pattern: String,
                              timeZone: TimeZone = .current,
                              locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone; cal.locale = locale
        var iso = Calendar(identifier: .iso8601); iso.timeZone = timeZone; iso.locale = locale
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let isoYear = iso.component(.yearForWeekOfYear, from: date)
        let isoWeek = iso.component(.weekOfYear, from: date)
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
            ("DD", { pad(c.day!, 2) }), ("D", { String(c.day!) }),
            ("dddd", { weekdays[c.weekday! - 1] }), ("ddd", { String(weekdays[c.weekday! - 1].prefix(3)) }),
            ("HH", { pad(c.hour!, 2) }), ("mm", { pad(c.minute!, 2) }), ("ss", { pad(c.second!, 2) }),
            ("gggg", { pad(isoYear, 4) }), ("ww", { pad(isoWeek, 2) }),
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
            ("MM", #"(\d{2})"#), ("M", #"(\d{1,2})"#), ("DD", #"(\d{2})"#), ("D", #"(\d{1,2})"#),
            ("dddd", "(" + weekdays.joined(separator: "|") + ")"),
            ("ddd", "(" + weekdays.map { String($0.prefix(3)) }.joined(separator: "|") + ")"),
            ("HH", #"(\d{2})"#), ("mm", #"(\d{2})"#), ("ss", #"(\d{2})"#),
            ("gggg", #"(\d{4})"#), ("ww", #"(\d{2})"#), ("Q", "([1-4])"),
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
        if let isoYear = int("gggg"), let week = int("ww") {
            var iso = Calendar(identifier: .iso8601); iso.timeZone = timeZone
            date = iso.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: isoYear))
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
            c.day = int("DD") ?? int("D") ?? 1
            c.hour = int("HH") ?? 0; c.minute = int("mm") ?? 0; c.second = int("ss") ?? 0
            var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
            date = cal.date(from: c)
        }
        guard let date, format(date, pattern, timeZone: timeZone) == string else { return nil }
        return date
    }

    private static func matches(_ chars: [Character], _ i: Int, _ tok: String) -> Bool {
        let t = Array(tok)
        guard i + t.count <= chars.count else { return false }
        for k in 0..<t.count where chars[i + k] != t[k] { return false }
        return true
    }
}

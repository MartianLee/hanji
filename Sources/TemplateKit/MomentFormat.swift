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

    private static func matches(_ chars: [Character], _ i: Int, _ tok: String) -> Bool {
        let t = Array(tok)
        guard i + t.count <= chars.count else { return false }
        for k in 0..<t.count where chars[i + k] != t[k] { return false }
        return true
    }
}

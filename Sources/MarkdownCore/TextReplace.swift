import Foundation

/// Literal (non-regex) find & replace over note text.
///
/// Offsets are UTF-16 so they line up with `NSString`/TextKit, which is what the
/// editor and the search snippets already speak. Matching is `.literal` — no
/// Unicode folding — so what the user typed is what gets replaced.
public enum TextReplace {
    /// Every non-overlapping occurrence, left to right.
    public static func ranges(of needle: String, in text: String,
                              caseSensitive: Bool = true) -> [Range<Int>] {
        let ns = text as NSString
        let needleLength = (needle as NSString).length
        // An empty needle would match at every offset without consuming anything,
        // so the scan below would never terminate. Nothing to find: say so.
        guard needleLength > 0, ns.length >= needleLength else { return [] }
        let options: NSString.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        var out: [Range<Int>] = []
        var start = 0
        while start <= ns.length - needleLength {
            let hit = ns.range(of: needle, options: options,
                               range: NSRange(location: start, length: ns.length - start))
            guard hit.location != NSNotFound else { break }
            out.append(hit.location..<(hit.location + hit.length))
            start = hit.location + hit.length
        }
        return out
    }

    public static func count(of needle: String, in text: String, caseSensitive: Bool = true) -> Int {
        ranges(of: needle, in: text, caseSensitive: caseSensitive).count
    }

    /// `text` with every occurrence replaced, or `nil` when the file would not
    /// change — callers use `nil` to skip the write (and the undo entry) entirely.
    ///
    /// The result is assembled from the original text around the match ranges, so
    /// a replacement that contains the needle (`a` → `aa`) is never rescanned.
    public static func apply(_ needle: String, with replacement: String, in text: String,
                             caseSensitive: Bool = true) -> String? {
        let hits = ranges(of: needle, in: text, caseSensitive: caseSensitive)
        guard !hits.isEmpty else { return nil }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for hit in hits {
            out += ns.substring(with: NSRange(location: cursor, length: hit.lowerBound - cursor))
            out += replacement
            cursor = hit.upperBound
        }
        out += ns.substring(from: cursor)
        return out == text ? nil : out
    }
}

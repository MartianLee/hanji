import Foundation

public struct ImageRef: Equatable {
    public let path: String
    public let line: Range<Int>     // the whole image line (UTF-16 offsets)
    public init(path: String, line: Range<Int>) { self.path = path; self.line = line }
}

public enum ImageParser {
    /// Own-line image references: `![[path]]` (embed) or `![alt](path)`.
    public static func images(in text: String) -> [ImageRef] {
        var out: [ImageRef] = []
        let ns = text as NSString
        let nl = UInt16(UnicodeScalar("\n").value)
        var start = 0
        while start <= ns.length {
            var end = start
            while end < ns.length && ns.character(at: end) != nl { end += 1 }
            // Only a line whose first non-blank is `!` can be an image; skip the
            // rest without building them (any non-ASCII lead is checked properly,
            // as trimming counts more than spaces and tabs as blank).
            var first = start
            while first < end, ns.character(at: first) == 0x20 || ns.character(at: first) == 0x09 { first += 1 }
            if first < end, ns.character(at: first) != 0x21, ns.character(at: first) < 0x80 {
                if end == ns.length { break }
                start = end + 1
                continue
            }
            let raw = ns.substring(with: NSRange(location: start, length: end - start))
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("![["), line.hasSuffix("]]") {
                var inner = String(line.dropFirst(3).dropLast(2))
                if let bar = inner.firstIndex(of: "|") { inner = String(inner[..<bar]) }
                inner = inner.trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty { out.append(ImageRef(path: inner, line: start..<end)) }
            } else if line.hasPrefix("!["), line.hasSuffix(")"), let p = line.range(of: "](") {
                let path = String(line[p.upperBound...].dropLast())
                if !path.isEmpty { out.append(ImageRef(path: path, line: start..<end)) }
            }
            if end == ns.length { break }
            start = end + 1
        }
        return out
    }
}

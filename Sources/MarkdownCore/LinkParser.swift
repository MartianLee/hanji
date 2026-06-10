import Foundation

/// A non-embed link found in a note body. `target` is the raw link target
/// (before `|` alias / `#` heading); `range` is the whole token in UTF-16.
public struct LinkRef: Equatable {
    public let target: String
    public let range: Range<Int>
    public init(target: String, range: Range<Int>) {
        self.target = target
        self.range = range
    }
}

/// Extracts wikilinks (`[[Target]]`, `[[Target|alias]]`, `[[Target#heading]]`)
/// and markdown links to `.md` files. Skips embeds/images (`![[…]]`, `![…](…)`),
/// external URLs, and anything inside fenced code blocks.
public enum LinkParser {
    private static let wiki = try! NSRegularExpression(pattern: #"(?<!\!)\[\[([^\[\]]+)\]\]"#)
    private static let md = try! NSRegularExpression(pattern: #"(?<!\!)\[[^\]]*\]\(([^)\s]+)\)"#)

    public static func links(in text: String) -> [LinkRef] {
        let ns = text as NSString
        let fenced = fencedRanges(ns)
        func inFence(_ r: NSRange) -> Bool { fenced.contains { NSIntersectionRange($0, r).length > 0 } }
        var out: [LinkRef] = []

        let full = NSRange(location: 0, length: ns.length)
        for m in wiki.matches(in: text, range: full) where !inFence(m.range) {
            var target = ns.substring(with: m.range(at: 1))
            if let bar = target.firstIndex(of: "|") { target = String(target[..<bar]) }
            if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
            target = target.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            out.append(LinkRef(target: target, range: m.range.location..<NSMaxRange(m.range)))
        }
        for m in md.matches(in: text, range: full) where !inFence(m.range) {
            var dest = ns.substring(with: m.range(at: 1))
            guard !dest.contains("://"), !dest.hasPrefix("#"), !dest.hasPrefix("mailto:") else { continue }
            if let hash = dest.firstIndex(of: "#") { dest = String(dest[..<hash]) }
            dest = dest.removingPercentEncoding ?? dest
            if dest.hasPrefix("./") { dest = String(dest.dropFirst(2)) }
            guard dest.lowercased().hasSuffix(".md") else { continue }
            out.append(LinkRef(target: dest, range: m.range.location..<NSMaxRange(m.range)))
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// UTF-16 ranges of fenced code blocks (``` … ```), line-based.
    private static func fencedRanges(_ ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var fenceStart: Int? = nil
        var pos = 0
        while pos < ns.length {
            let line = ns.lineRange(for: NSRange(location: pos, length: 0))
            var content = ns.substring(with: line)
            if content.hasSuffix("\n") { content.removeLast() }
            if content.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let start = fenceStart {
                    ranges.append(NSRange(location: start, length: NSMaxRange(line) - start))
                    fenceStart = nil
                } else {
                    fenceStart = line.location
                }
            }
            pos = NSMaxRange(line)
            if line.length == 0 { break }
        }
        if let start = fenceStart {   // unterminated fence runs to EOF
            ranges.append(NSRange(location: start, length: ns.length - start))
        }
        return ranges
    }
}

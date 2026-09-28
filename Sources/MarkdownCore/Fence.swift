import Foundation

/// A code fence line, as CommonMark defines it — the one rule every parser uses
/// to decide where code starts and ends.
public struct Fence: Hashable {
    public let marker: Character   // ` or ~
    public let length: Int
    public let info: String        // the language, on an opening fence
    /// Columns of indent before the marker (a tab runs to the next multiple of 4).
    public let indent: Int

    /// The fence `line` opens: 3+ backticks or tildes after at most 3 columns of
    /// indent (4 is an indented code line, not a fence) — or deeper inside a list
    /// item (`inList`, see `ListContext`), whose fences count their indent from
    /// the item's text: GitHub READMEs nest `    ```swift` under `- `. A trailing
    /// `\r` (CRLF) is ignored; a backtick fence's info string can't contain a
    /// backtick.
    public static func opening(_ line: String, inList: Bool = false) -> Fence? {
        guard let fence = parse(line), fence.indent <= 3 || inList else { return nil }
        return fence
    }

    /// Whether `line` closes the block this fence opened: a bare run of the same
    /// marker, at least as long (so ```` ```js ```` inside a block is code), indented
    /// at most 3 columns — or, for a fence nested in a list item, at most 3 more
    /// than the fence itself.
    public func isClosed(by line: String) -> Bool {
        guard let other = Fence.parse(line), other.indent <= (indent <= 3 ? 3 : indent + 3) else { return false }
        return other.marker == marker && other.length >= length && other.info.isEmpty
    }

    /// A fence-shaped line at any indent.
    static func parse(_ line: String) -> Fence? {
        var chars = Substring(line)
        if chars.last == "\r" { chars = chars.dropLast() }
        var indent = 0
        while let c = chars.first, c == " " || c == "\t" {
            indent = c == "\t" ? (indent / 4 + 1) * 4 : indent + 1
            chars = chars.dropFirst()
        }
        guard let marker = chars.first, marker == "`" || marker == "~" else { return nil }
        let length = chars.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = chars.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if marker == "`" && info.contains("`") { return nil }
        return Fence(marker: marker, length: length, info: info, indent: indent)
    }
}

/// Whether the text so far leaves us inside a list item — where a fence may be
/// indented past 3 columns. A list item starts it; blank lines and indented
/// lines (the item's continuation) keep it; anything else at the margin ends
/// it. Lines inside code don't count.
public enum ListContext {
    public static func after(_ line: String, inList: Bool) -> Bool {
        let u = line.utf16
        guard let first = u.first(where: { $0 != 0x20 && $0 != 0x09 }), first != 0x0D else { return inList }
        if u.first == 0x20 || u.first == 0x09 { return inList || isItem(line) }
        return isItem(line)
    }

    /// `after(_:inList:)` for the line `ns[start..<end]`, without building it.
    public static func after(_ ns: NSString, from start: Int, to end: Int, inList: Bool) -> Bool {
        var i = start
        while i < end, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
        guard i < end, ns.character(at: i) != 0x0D else { return inList }
        let item = isItem(ns, from: start, to: end)
        return i > start ? inList || item : item
    }

    /// `isItem(_:)` for the line `ns[start..<end]`.
    public static func isItem(_ ns: NSString, from start: Int, to end: Int) -> Bool {
        var i = start
        while i < end, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
        guard i < end else { return false }
        func spaceAfter(_ j: Int) -> Bool { j + 1 < end && ns.character(at: j + 1) == 0x20 }
        let c = ns.character(at: i)
        if c == 0x2D || c == 0x2A || c == 0x2B { return spaceAfter(i) }
        var digits = 0
        while i < end, ns.character(at: i) >= 0x30, ns.character(at: i) <= 0x39 {
            digits += 1
            if digits > 9 { return false }
            i += 1
        }
        guard digits > 0, i < end, ns.character(at: i) == 0x2E || ns.character(at: i) == 0x29 else { return false }
        return spaceAfter(i)
    }

    /// `ListIndent.isListItem`, answered on the line's UTF-16 without building
    /// anything: this runs on every line of every parse (the check group
    /// NestedFence holds the two to the same answers).
    public static func isItem(_ line: String) -> Bool {
        let u = line.utf16
        var i = u.startIndex
        while i != u.endIndex, u[i] == 0x20 || u[i] == 0x09 { i = u.index(after: i) }
        guard i != u.endIndex else { return false }
        func spaceAfter(_ j: String.UTF16View.Index) -> Bool {
            let n = u.index(after: j)
            return n != u.endIndex && u[n] == 0x20
        }
        let c = u[i]
        if c == 0x2D || c == 0x2A || c == 0x2B { return spaceAfter(i) }   // - * +
        var digits = 0
        while i != u.endIndex, u[i] >= 0x30, u[i] <= 0x39 {
            digits += 1
            if digits > 9 { return false }
            i = u.index(after: i)
        }
        guard digits > 0, i != u.endIndex, u[i] == 0x2E || u[i] == 0x29 else { return false }   // . )
        return spaceAfter(i)
    }
}

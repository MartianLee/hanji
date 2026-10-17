import Foundation

/// What Return should do at the end of a list line: carry the marker onto the next
/// line (numbers incrementing), or — when the item is empty — drop the marker and
/// leave the list, the way every markdown editor behaves.
public enum ListContinuation {
    public enum Action: Equatable {
        case none                     // not a list item — a plain newline
        case `continue`(String)       // text to start the next line with
        case end(markerLength: Int)   // empty item: delete this many leading units
    }

    private static let space = UInt16(0x20)
    private static let tab = UInt16(0x09)
    private static let openBracket = UInt16(0x5B)
    private static let closeBracket = UInt16(0x5D)
    private static let dot = UInt16(0x2E)
    private static let closeParen = UInt16(0x29)
    private static let zero = UInt16(0x30)
    private static let nine = UInt16(0x39)

    private static func isBullet(_ c: UInt16) -> Bool {
        c == UInt16(0x2D) || c == UInt16(0x2A) || c == UInt16(0x2B)   // - * +
    }

    public static func action(for line: String) -> Action {
        let ns = line as NSString
        var i = 0
        while i < ns.length, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1 }
        guard i < ns.length else { return .none }
        let indent = ns.substring(to: i)
        if let task = taskAction(ns, from: i, indent: indent) { return task }
        if let bullet = bulletAction(ns, from: i, indent: indent) { return bullet }
        return orderedAction(ns, from: i, indent: indent)
    }

    /// `- [ ] ` / `- [x] ` — a continued task always starts unchecked.
    private static func taskAction(_ ns: NSString, from i: Int, indent: String) -> Action? {
        guard ns.length >= i + 6, isBullet(ns.character(at: i)), ns.character(at: i + 1) == space,
              ns.character(at: i + 2) == openBracket, ns.character(at: i + 4) == closeBracket,
              ns.character(at: i + 5) == space else { return nil }
        let mark = ns.character(at: i + 3)
        guard mark == space || mark == UInt16(0x78) || mark == UInt16(0x58) else { return nil }
        if ns.length == i + 6 { return .end(markerLength: i + 6) }
        return .continue(indent + ns.substring(with: NSRange(location: i, length: 2)) + "[ ] ")
    }

    /// `- ` / `* ` / `+ ` — the item's own bullet character is carried forward.
    private static func bulletAction(_ ns: NSString, from i: Int, indent: String) -> Action? {
        guard ns.length >= i + 2, isBullet(ns.character(at: i)),
              ns.character(at: i + 1) == space else { return nil }
        if ns.length == i + 2 { return .end(markerLength: i + 2) }
        return .continue(indent + ns.substring(with: NSRange(location: i, length: 2)))
    }

    /// `1. ` / `2) ` — the next item gets the next number, same delimiter.
    private static func orderedAction(_ ns: NSString, from i: Int, indent: String) -> Action {
        var j = i
        var value = 0
        while j < ns.length, ns.character(at: j) >= zero, ns.character(at: j) <= nine {
            value = value * 10 + Int(ns.character(at: j) - zero)
            j += 1
            if j - i > 9 { return .none }   // not a list marker, just a long number
        }
        guard j > i, j < ns.length else { return .none }
        let delim = ns.character(at: j)
        guard delim == dot || delim == closeParen else { return .none }
        guard j + 1 < ns.length, ns.character(at: j + 1) == space else { return .none }
        if ns.length == j + 2 { return .end(markerLength: j + 2) }
        return .continue(indent + "\(value + 1)" + ns.substring(with: NSRange(location: j, length: 2)))
    }
}

/// What Tab / Shift-Tab do to a list line: nest it one level deeper, or pull it
/// back out. Nesting in markdown is just leading whitespace, so the whole job is
/// deciding how much of it to add or remove.
public enum ListIndent {
    /// One nesting level. A tab is what most markdown editors insert, and both the
    /// tokenizer and `ListContinuation` already read tabs and spaces alike.
    public static let unit = "\t"
    /// How many spaces make one level, for lists that were indented with spaces.
    public static let spacesPerUnit = 4

    /// Whether Tab/Shift-Tab belong to the list on this line at all. Callers need
    /// this apart from `outdent`, which also returns nil for a list item that is
    /// already at the outermost level — a case where the key should be swallowed
    /// rather than handed back to the text view.
    public static func isListItem(_ line: String) -> Bool {
        ListContinuation.action(for: line) != .none
    }

    /// Tab: what to insert at the start of `line`, or nil when the line isn't a
    /// list item and Tab should do its ordinary thing.
    public static func indent(for line: String) -> String? {
        guard isListItem(line) else { return nil }
        return unit
    }

    /// Shift-Tab: how many leading UTF-16 units to drop, or nil when the line
    /// isn't a list item or is already at the outermost level.
    public static func outdent(for line: String) -> Int? {
        guard isListItem(line) else { return nil }
        let ns = line as NSString
        guard ns.length > 0 else { return nil }
        if ns.character(at: 0) == UInt16(0x09) { return 1 }
        var spaces = 0
        while spaces < ns.length, spaces < spacesPerUnit,
              ns.character(at: spaces) == UInt16(0x20) { spaces += 1 }
        return spaces > 0 ? spaces : nil
    }
}

/// Keeps an ordered list counting 1, 2, 3 after the edits that reshuffle it:
/// Tab nests an item (it starts the sublist's own count), Shift-Tab brings it
/// back (it takes its place in the outer count), and Return continues a list
/// whose items were copied in from elsewhere. Markdown itself would render the
/// numbers as written, so the text is what has to change.
public enum ListRenumber {
    /// Put `number` where `range` is.
    public struct Edit: Equatable {
        public let range: NSRange
        public let number: String
    }

    private struct Item {
        let width: Int            // indent, a tab counting as ListIndent.spacesPerUnit
        let ordered: Bool
        let delimiter: UInt16
        let number: Int
        let numberRange: NSRange
    }

    /// The edits that renumber the list around `offset`, in text order; empty when
    /// the list already counts right. A run of items is one indent level under one
    /// parent; it keeps the number it starts at, except the line holding `moved`
    /// (one Tab or Shift-Tab just moved), which starts its run at 1 when it leads
    /// it. The list is the lines around `offset` up to a blank line or a line of
    /// text at the left edge; lines `isCode` claims are code, never items.
    public static func edits(in text: String, around offset: Int, moved: Int? = nil,
                             isCode: (Int) -> Bool = { _ in false }) -> [Edit] {
        let ns = text as NSString
        guard offset <= ns.length else { return [] }
        let lines = block(ns, around: offset, isCode: isCode)
        let movedLine = moved.map { ns.lineRange(for: NSRange(location: $0, length: 0)).location }
        // The open run at each indent, innermost last: its kind and last number.
        var runs: [(width: Int, ordered: Bool, delimiter: UInt16, last: Int)] = []
        var out: [Edit] = []
        for line in lines {
            guard !isCode(line.location), let item = item(ns, line) else { continue }
            while let top = runs.last, top.width > item.width { runs.removeLast() }
            var number = item.number
            if let top = runs.last, top.width == item.width {
                if top.ordered && item.ordered && top.delimiter == item.delimiter {
                    number = top.last + 1
                } else if item.ordered && line.location == movedLine {
                    number = 1
                }
                runs.removeLast()
            } else if item.ordered && line.location == movedLine {
                number = 1
            }
            runs.append((item.width, item.ordered, item.delimiter, number))
            if item.ordered && number != item.number {
                out.append(Edit(range: item.numberRange, number: String(number)))
            }
        }
        return out
    }

    /// The list's lines (each without its newline) around `offset`.
    private static func block(_ ns: NSString, around offset: Int, isCode: (Int) -> Bool) -> [NSRange] {
        func content(_ r: NSRange) -> NSRange {
            var length = r.length
            while length > 0, ns.character(at: r.location + length - 1) == 0x0A
                    || ns.character(at: r.location + length - 1) == 0x0D { length -= 1 }
            return NSRange(location: r.location, length: length)
        }
        func belongs(_ r: NSRange) -> Bool {
            guard r.length > 0 else { return false }
            let first = ns.character(at: r.location)
            if first == 0x20 || first == 0x09 || isCode(r.location) { return true }
            return item(ns, r) != nil
        }
        let here = content(ns.lineRange(for: NSRange(location: offset, length: 0)))
        guard belongs(here) else { return [] }
        var above: [NSRange] = []
        var start = here.location
        while start > 0 {
            let r = content(ns.lineRange(for: NSRange(location: start - 1, length: 0)))
            guard belongs(r) else { break }
            above.append(r)
            start = r.location
        }
        var lines = above.reversed() + [here]
        var end = NSMaxRange(ns.lineRange(for: NSRange(location: offset, length: 0)))
        while end < ns.length {
            let full = ns.lineRange(for: NSRange(location: end, length: 0))
            let r = content(full)
            guard belongs(r) else { break }
            lines.append(r)
            end = NSMaxRange(full)
        }
        return lines
    }

    /// The list item on `line`, or nil when it isn't one.
    private static func item(_ ns: NSString, _ line: NSRange) -> Item? {
        var i = line.location, width = 0
        let end = NSMaxRange(line)
        while i < end {
            let c = ns.character(at: i)
            if c == 0x20 { width += 1 } else if c == 0x09 { width += ListIndent.spacesPerUnit } else { break }
            i += 1
        }
        guard i < end else { return nil }
        let c = ns.character(at: i)
        if c == 0x2D || c == 0x2A || c == 0x2B {   // - * +
            guard i + 1 < end, ns.character(at: i + 1) == 0x20 else { return nil }
            return Item(width: width, ordered: false, delimiter: c, number: 0, numberRange: NSRange())
        }
        var j = i, number = 0
        while j < end, j - i < 9, ns.character(at: j) >= 0x30, ns.character(at: j) <= 0x39 {
            number = number * 10 + Int(ns.character(at: j) - 0x30)
            j += 1
        }
        guard j > i, j + 1 < end else { return nil }
        let delimiter = ns.character(at: j)
        guard delimiter == 0x2E || delimiter == 0x29, ns.character(at: j + 1) == 0x20 else { return nil }
        return Item(width: width, ordered: true, delimiter: delimiter, number: number,
                    numberRange: NSRange(location: i, length: j - i))
    }
}

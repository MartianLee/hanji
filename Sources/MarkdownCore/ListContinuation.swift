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

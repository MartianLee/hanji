import Foundation

/// A code fence line, as CommonMark defines it — the one rule every parser uses
/// to decide where code starts and ends.
public struct Fence: Hashable {
    public let marker: Character   // ` or ~
    public let length: Int
    public let info: String        // the language, on an opening fence

    /// The fence `line` opens: 3+ backticks or tildes after at most 3 spaces of
    /// indent (4 is an indented code line, not a fence). A trailing `\r` (CRLF)
    /// is ignored; a backtick fence's info string can't contain a backtick.
    public static func opening(_ line: String) -> Fence? {
        var chars = Substring(line)
        if chars.last == "\r" { chars = chars.dropLast() }
        let indent = chars.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = chars.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if marker == "`" && info.contains("`") { return nil }
        return Fence(marker: marker, length: length, info: info)
    }

    /// Whether `line` closes the block this fence opened: a bare run of the same
    /// marker, at least as long (so ```` ```js ```` inside a block is code).
    public func isClosed(by line: String) -> Bool {
        guard let other = Fence.opening(line) else { return false }
        return other.marker == marker && other.length >= length && other.info.isEmpty
    }
}

import Foundation

/// A pasted markdown table gets lines of its own, so it's drawn as a grid the
/// moment it lands. Pasted at the end of the text with nothing after it, the
/// caret would sit on the table's last row — and a table with the caret in it
/// shows its source; pasted mid-line, its first or last row would run into the
/// text around it and stop being a table row at all.
public enum TablePaste {
    /// The text to insert for a paste of `text`: a newline after a table that
    /// ends it, so the caret lands below the grid; a newline before a table that
    /// starts it when the paste goes in mid-line (`atLineStart` false). Anything
    /// else is pasted as it is.
    public static func adjusted(_ text: String, atLineStart: Bool) -> String {
        let tables = TableParser.tables(in: text)
        guard let first = tables.first, let last = tables.last else { return text }
        var out = text
        if last.range.upperBound == (text as NSString).length { out += "\n" }
        if !atLineStart, first.range.lowerBound == 0 { out = "\n" + out }
        return out
    }
}

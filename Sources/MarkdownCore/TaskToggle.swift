import Foundation

public enum TaskToggle {
    /// If `clickOffset` lands on a task line's checkbox brackets (`[ ]`/`[x]`),
    /// returns the UTF-16 offset of the state char and its replacement; else nil.
    public static func toggle(in text: String, at clickOffset: Int) -> (offset: Int, replacement: String)? {
        let ns = text as NSString
        let len = ns.length
        guard clickOffset >= 0, clickOffset <= len else { return nil }

        var lineStart = clickOffset
        while lineStart > 0 && ns.character(at: lineStart - 1) != 0x0A { lineStart -= 1 }
        // Nested tasks sit after an indent (spaces/tabs), same as the tokenizer
        // that draws their checkbox.
        while lineStart < len, ns.character(at: lineStart) == 0x20 || ns.character(at: lineStart) == 0x09 {
            lineStart += 1
        }

        guard lineStart + 6 <= len else { return nil }
        let dash = UInt16(UnicodeScalar("-").value), sp = UInt16(UnicodeScalar(" ").value)
        let lb = UInt16(UnicodeScalar("[").value), rb = UInt16(UnicodeScalar("]").value)
        guard ns.character(at: lineStart) == dash, ns.character(at: lineStart + 1) == sp,
              ns.character(at: lineStart + 2) == lb, ns.character(at: lineStart + 4) == rb,
              ns.character(at: lineStart + 5) == sp else { return nil }

        guard clickOffset >= lineStart + 2, clickOffset <= lineStart + 4 else { return nil }
        let state = ns.character(at: lineStart + 3)
        let x = UInt16(UnicodeScalar("x").value), X = UInt16(UnicodeScalar("X").value)
        let isDone = (state == x || state == X)
        return (offset: lineStart + 3, replacement: isDone ? " " : "x")
    }
}

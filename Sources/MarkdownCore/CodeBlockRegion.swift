import Foundation

public struct CodeBlockRegion: Equatable {
    public let language: String        // "" if none
    public let body: Range<Int>        // inner text (between fences), UTF-16
    public let full: Range<Int>        // whole block incl fences
    public init(language: String, body: Range<Int>, full: Range<Int>) {
        self.language = language; self.body = body; self.full = full
    }
}

public enum CodeBlockParser {
    /// Finds fenced code blocks (``` …). A block opens on a line starting with ```
    /// (optionally followed by a language) and closes on the next line that starts with ```.
    public static func regions(in text: String) -> [CodeBlockRegion] {
        var out: [CodeBlockRegion] = []
        let ns = text as NSString
        let length = ns.length
        let newline = UInt16(UnicodeScalar("\n").value)

        var lineStart = 0
        var open: (fenceStart: Int, bodyStart: Int, lang: String)? = nil
        while lineStart <= length {
            var lineEnd = lineStart
            while lineEnd < length && ns.character(at: lineEnd) != newline { lineEnd += 1 }
            let line = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            let isFence = line.hasPrefix("```")
            if let o = open {
                if isFence {
                    let bodyEnd = lineStart > o.bodyStart ? lineStart - 1 : o.bodyStart
                    out.append(CodeBlockRegion(language: o.lang, body: o.bodyStart..<bodyEnd, full: o.fenceStart..<lineEnd))
                    open = nil
                }
            } else if isFence {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let bodyStart = (lineEnd == length) ? lineEnd : lineEnd + 1
                open = (fenceStart: lineStart, bodyStart: bodyStart, lang: lang)
            }
            if lineEnd == length { break }
            lineStart = lineEnd + 1
        }
        return out
    }
}

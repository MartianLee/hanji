import Foundation

/// Scalar `key: value` pairs from a leading frontmatter block (opened by `---`
/// on line 1, closed by `---`). Lists, nested maps (indented lines), and empty
/// values are skipped; quotes are stripped; keys are lowercased.
public enum Frontmatter {
    /// UTF-16 range of the leading frontmatter block, both `---` lines included,
    /// or nil when the note has none (a `---` that's never closed isn't one).
    public static func range(in text: String) -> Range<Int>? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        var pos = 0
        var index = 0
        while pos < ns.length {
            let lr = ns.lineRange(for: NSRange(location: pos, length: 0))
            var line = ns.substring(with: lr)
            while line.last?.isNewline == true { line.removeLast() }
            let isDelimiter = line.trimmingCharacters(in: .whitespaces) == "---"
            if index == 0 && !isDelimiter { return nil }
            if index > 0 && isDelimiter { return 0..<(lr.location + (line as NSString).length) }
            pos = NSMaxRange(lr); index += 1
            if lr.length == 0 { break }
        }
        return nil
    }

    public static func parse(_ text: String) -> [String: String] {
        let ns = text as NSString
        guard ns.length > 0 else { return [:] }
        let firstLine = ns.lineRange(for: NSRange(location: 0, length: 0))
        var first = ns.substring(with: firstLine)
        while first.last?.isNewline == true { first.removeLast() }   // "\r\n" is one Character
        guard first.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

        var pending: [String: String] = [:]
        var pos = NSMaxRange(firstLine)
        while pos < ns.length {
            let lr = ns.lineRange(for: NSRange(location: pos, length: 0))
            var line = ns.substring(with: lr)
            while line.last?.isNewline == true { line.removeLast() }
            if line.trimmingCharacters(in: .whitespaces) == "---" { return pending }   // closed
            // Indented lines belong to nested structures — skip them.
            if !line.hasPrefix(" ") && !line.hasPrefix("\t"),
               let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, !key.hasPrefix("-"), !value.isEmpty {
                    if value.count >= 2,
                       (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                       (value.hasPrefix("'") && value.hasSuffix("'")) {
                        value = String(value.dropFirst().dropLast())
                    }
                    pending[key] = value
                }
            }
            pos = NSMaxRange(lr)
            if lr.length == 0 { break }
        }
        return [:]   // never closed → not frontmatter
    }
}

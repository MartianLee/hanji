import Foundation

/// Scalar `key: value` pairs from a leading frontmatter block (opened by `---`
/// on line 1, closed by `---`). Lists, nested maps (indented lines), and empty
/// values are skipped; quotes are stripped; keys are lowercased.
public enum Frontmatter {
    public static func parse(_ text: String) -> [String: String] {
        let ns = text as NSString
        guard ns.length > 0 else { return [:] }
        let firstLine = ns.lineRange(for: NSRange(location: 0, length: 0))
        var first = ns.substring(with: firstLine)
        if first.hasSuffix("\n") { first.removeLast() }
        guard first.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

        var pending: [String: String] = [:]
        var pos = NSMaxRange(firstLine)
        while pos < ns.length {
            let lr = ns.lineRange(for: NSRange(location: pos, length: 0))
            var line = ns.substring(with: lr)
            if line.hasSuffix("\n") { line.removeLast() }
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

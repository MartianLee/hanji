import Foundation

/// The `dataview` block's query language — the PRD's LIST/TABLE subset.
public enum DataviewQuery {
    public enum Kind: Equatable { case list, table }
    public enum Source: Equatable { case tag(String), folder(String), all }
    public enum Op: String, Equatable, CaseIterable { case le = "<=", ge = ">=", ne = "!=", eq = "=", lt = "<", gt = ">" }
    public struct Condition: Equatable {
        public let field: String
        public let op: Op
        public let value: String
        public init(field: String, op: Op, value: String) { self.field = field; self.op = op; self.value = value }
    }
    public struct SortKey: Equatable {
        public let field: String
        public let ascending: Bool
        public init(field: String, ascending: Bool) { self.field = field; self.ascending = ascending }
    }
    public struct Parsed: Equatable {
        public let kind: Kind
        public let columns: [String]
        public let source: Source
        public let conditions: [Condition]
        public let sort: SortKey?
        public init(kind: Kind, columns: [String], source: Source, conditions: [Condition], sort: SortKey?) {
            self.kind = kind; self.columns = columns; self.source = source
            self.conditions = conditions; self.sort = sort
        }
    }
    /// One result row (defined here so renderers don't import the index module).
    public struct ResultRow: Identifiable {
        public let path: String
        public let title: String
        public let values: [String?]
        public var id: String { path }
        public init(path: String, title: String, values: [String?]) {
            self.path = path; self.title = title; self.values = values
        }
    }

    // `\b…\b` protects compound names (sort_order, transformer), but a column or
    // field literally named `from`/`where`/`sort` is read as the clause keyword
    // and the query fails to parse (renderer shows an error widget) — acceptable
    // for the subset; revisit with a real tokenizer if it bites.
    // No trailing `\s*` before `$`: `parse` strips that whitespace first. Next to
    // the lazy groups, ICU rescanned the whole run for every character the groups
    // grew by — `TABLE`, 16k spaces and a column name took seconds.
    private static let shape = try! NSRegularExpression(
        pattern: #"^\s*(LIST|TABLE)\b(.*?)(?:\bFROM\b(.*?))?(?:\bWHERE\b(.*?))?(?:\bSORT\b(.*?))?$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// nil = syntax error (renderer shows an error widget).
    public static func parse(_ source: String) -> Parsed? {
        // `\p{White_Space}` is exactly ICU's `\s` (Foundation's
        // `.whitespacesAndNewlines` also holds U+200B, which `\s` does not).
        var scalars = Substring(source.replacingOccurrences(of: "\n", with: " ")).unicodeScalars
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        let flat = String(scalars)
        let ns = flat as NSString
        guard let m = shape.firstMatch(in: flat, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r).trimmingCharacters(in: .whitespaces)
        }
        let kind: Kind = group(1)?.uppercased() == "TABLE" ? .table : .list

        let colsPart = group(2) ?? ""
        var columns: [String] = []
        if kind == .table {
            columns = colsPart.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        } else if !colsPart.isEmpty {
            return nil   // LIST takes no columns
        }

        let source: Source
        switch group(3) {
        case nil, "": source = .all
        case let f? where f.hasPrefix("#") && f.count > 1:
            source = .tag(String(f.dropFirst()).lowercased())
        case let f? where f.hasPrefix("\"") && f.hasSuffix("\"") && f.count >= 2:
            source = .folder(String(f.dropFirst().dropLast()))
        default: return nil
        }

        var conditions: [Condition] = []
        if let wherePart = group(4), !wherePart.isEmpty {
            for clause in splitConditions(wherePart) {
                guard let cond = parseCondition(clause) else { return nil }
                conditions.append(cond)
            }
        }

        var sort: SortKey?
        if let sortPart = group(5), !sortPart.isEmpty {
            let bits = sortPart.split(separator: " ").map(String.init)
            guard bits.count <= 2, let field = bits.first else { return nil }
            var ascending = true
            if bits.count == 2 {
                switch bits[1].uppercased() {
                case "ASC": ascending = true
                case "DESC": ascending = false
                default: return nil
                }
            }
            sort = SortKey(field: field.lowercased(), ascending: ascending)
        }
        return Parsed(kind: kind, columns: columns, source: source, conditions: conditions, sort: sort)
    }

    private static func parseCondition(_ clause: String) -> Condition? {
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        for op in Op.allCases {   // <= and >= and != before <, >, = (CaseIterable order above)
            if let range = trimmed.range(of: op.rawValue) {
                let field = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces).lowercased()
                var value = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !field.isEmpty, !value.isEmpty else { return nil }
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                return Condition(field: field, op: op, value: value)
            }
        }
        return nil
    }

    /// Split a WHERE clause on " AND " (case-insensitive) that occurs OUTSIDE a
    /// double-quoted value, so `project = "Design and Research"` stays one clause.
    private static func splitConditions(_ s: String) -> [String] {
        let chars = Array(s)
        var parts: [String] = []
        var start = 0
        var i = 0
        var inQuote = false
        while i < chars.count {
            if chars[i] == "\"" { inQuote.toggle(); i += 1; continue }
            if !inQuote, i + 5 <= chars.count,
               String(chars[i..<i + 5]).caseInsensitiveCompare(" and ") == .orderedSame {
                parts.append(String(chars[start..<i]))
                i += 5
                start = i
                continue
            }
            i += 1
        }
        parts.append(String(chars[start..<chars.count]))
        return parts
    }

    /// Legacy v0 helper (`LIST FROM #tag` → tag) kept for compatibility.
    public static func tagForListQuery(_ source: String) -> String? {
        guard let q = parse(source), q.kind == .list, case .tag(let t) = q.source else { return nil }
        return t
    }
}

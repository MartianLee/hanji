import Foundation

/// Case-insensitive subsequence matching with a simple proximity score (lower = better).
public enum FuzzyFilter {
    public static func score(_ query: String, _ text: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        var qi = 0
        var firstMatch: Int? = nil
        var lastMatch = -1
        var gaps = 0
        for (ti, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            if firstMatch == nil { firstMatch = ti }
            if lastMatch >= 0 { gaps += ti - lastMatch - 1 }
            lastMatch = ti
            qi += 1
        }
        guard qi == q.count else { return nil }
        return (firstMatch ?? 0) + gaps
    }

    public static func filter<T>(_ query: String, _ items: [T], key: (T) -> String) -> [T] {
        if query.isEmpty { return items }
        return items
            .compactMap { item in score(query, key(item)).map { (item, $0) } }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
    }
}

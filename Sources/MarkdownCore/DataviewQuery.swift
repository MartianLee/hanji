import Foundation

public enum DataviewQuery {
    /// Parses the Dataview-lite subset `LIST FROM #tag` (case-insensitive),
    /// returning the tag (without `#`), or nil for unsupported queries.
    public static func tagForListQuery(_ source: String) -> String? {
        let parts = source
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        guard parts.count >= 3,
              parts[0].uppercased() == "LIST",
              parts[1].uppercased() == "FROM",
              parts[2].hasPrefix("#") else { return nil }
        return String(parts[2].dropFirst())
    }
}

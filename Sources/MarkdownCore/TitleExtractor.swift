import Foundation

public enum TitleExtractor {
    /// Returns the first ATX H1 ("# ...") text, else the fallback (e.g. filename).
    public static func title(fromMarkdown text: String, fallback: String) -> String {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return title }
            }
        }
        return fallback
    }
}

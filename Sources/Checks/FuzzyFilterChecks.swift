import Foundation
import MarkdownCore

func fuzzyFilterChecks() {
    expect(FuzzyFilter.score("dv", "Daily View") != nil, "subsequence matches (case-insensitive)")
    expect(FuzzyFilter.score("xyz", "Daily") == nil, "non-subsequence → nil")
    expect(FuzzyFilter.score("", "anything") == 0, "empty query scores 0")
    // Closer-together matches rank better (lower score).
    let tight = FuzzyFilter.score("ab", "abXX")!
    let loose = FuzzyFilter.score("ab", "aXXb")!
    expect(tight < loose, "contiguous match ranks before scattered")

    let items = ["Open today's daily note", "Open this week's note", "New note from template…"]
    let filtered = FuzzyFilter.filter("tmpl", items, key: { $0 })
    expectEqual(filtered.first, "New note from template…", "fuzzy filter ranks best match first")
    expectEqual(FuzzyFilter.filter("", items, key: { $0 }).count, 3, "empty query keeps all")
}

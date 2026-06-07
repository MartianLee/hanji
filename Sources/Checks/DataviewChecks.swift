import Foundation
import MarkdownCore
import VaultKit

func tagsChecks() {
    expectEqual(Tags.extract(from: "todo #daily and #proj/sub here"), ["daily", "proj/sub"], "extracts tags")
    expect(Tags.extract(from: "# Heading line").isEmpty, "ATX heading is not a tag")
    expectEqual(Tags.extract(from: "#x #x"), ["x"], "dedup")
}

func dataviewQueryChecks() {
    expectEqual(DataviewQuery.tagForListQuery("LIST FROM #proj"), "proj", "parses LIST FROM #tag")
    expectEqual(DataviewQuery.tagForListQuery("list from #x"), "x", "case-insensitive")
    expect(DataviewQuery.tagForListQuery("TABLE foo") == nil, "non-LIST is nil")
    expect(DataviewQuery.tagForListQuery("LIST FROM proj") == nil, "needs # prefix")
}

func indexTagsChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mk-tags-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try? "# A\n#daily note".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    try? "# B\nno tags".write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

    let index = (try? MetadataIndex.build(from: Vault(root: root))) ?? MetadataIndex()
    let daily = index.notes(withTag: "daily")
    expectEqual(daily.count, 1, "one note with #daily")
    expectEqual(daily.first?.title, "A", "correct note found by tag")
}

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

func dataviewParseChecks() {
    // Full TABLE query.
    let q = DataviewQuery.parse("""
    TABLE status, priority FROM #proj
    WHERE priority >= 2 AND status != "done"
    SORT priority DESC
    """)
    expect(q != nil, "table query parses")
    expectEqual(q?.kind, .table, "kind table")
    expectEqual(q?.columns ?? [], ["status", "priority"], "columns kept in order, lowercased")
    expectEqual(q?.source, .tag("proj"), "tag source")
    expectEqual(q?.conditions.count, 2, "two AND conditions")
    expectEqual(q?.conditions.first, DataviewQuery.Condition(field: "priority", op: .ge, value: "2"), "numeric condition")
    expectEqual(q?.conditions.last, DataviewQuery.Condition(field: "status", op: .ne, value: "done"), "string condition unquoted")
    expectEqual(q?.sort, DataviewQuery.SortKey(field: "priority", ascending: false), "sort desc")

    // LIST + folder source + default sort direction.
    let l = DataviewQuery.parse("LIST FROM \"Projects/Sub\" SORT file.name")
    expectEqual(l?.kind, .list, "list kind")
    expectEqual(l?.source, .folder("Projects/Sub"), "folder source")
    expectEqual(l?.sort, DataviewQuery.SortKey(field: "file.name", ascending: true), "sort default asc")

    // No FROM → whole vault; no WHERE/SORT.
    let all = DataviewQuery.parse("TABLE status")
    expectEqual(all?.source, .all, "no FROM → all")
    expect(all?.conditions.isEmpty ?? false, "no conditions")
    expect(all?.sort == nil, "no sort")

    // Errors → nil.
    expect(DataviewQuery.parse("PIVOT x") == nil, "unknown verb")
    expect(DataviewQuery.parse("LIST FROM proj") == nil, "bare FROM target")
    expect(DataviewQuery.parse("TABLE a WHERE b ~ 2") == nil, "unknown operator")

    // Legacy wrapper unchanged.
    expectEqual(DataviewQuery.tagForListQuery("LIST FROM #proj"), "proj", "legacy wrapper")
    expect(DataviewQuery.tagForListQuery("TABLE foo") == nil, "wrapper rejects table")
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

import Foundation
import MKSearchKit
import MarkdownCore
import AppCore

func searchIndexChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-si-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }

    // Per-vault DB path: deterministic, under Application Support, outside the vault.
    let dbURL = SearchIndex.indexFileURL(forVault: vault)
    expect(dbURL.path.contains("Application Support"), "index lives in Application Support")
    expect(!dbURL.path.hasPrefix(vault.path), "index lives outside the vault")
    expectEqual(SearchIndex.indexFileURL(forVault: vault), dbURL, "path derivation is deterministic")
    defer { try? fm.removeItem(at: dbURL) }

    // Opening creates the DB file with the schema in place.
    let index = try? SearchIndex(vaultRoot: vault)
    expect(index != nil, "index opens")
    expect(fm.fileExists(atPath: dbURL.path), "DB file created")
}

func searchReindexChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-sr-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault.appendingPathComponent("Sub"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "# Hello\nfirst body".write(to: vault.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    try? "deep text".write(to: vault.appendingPathComponent("Sub/b.md"), atomically: true, encoding: .utf8)
    try? "ignored".write(to: vault.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)

    guard let index = try? SearchIndex(vaultRoot: vault) else { expect(false, "index opens"); return }
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }

    try? index.reindexAll(vault: vault)
    expectEqual(try? index.indexedCount(), 2, "two md files indexed (txt skipped)")

    // mtime-skip: a second full pass touches nothing.
    expectEqual(try? index.reindexAll(vault: vault), 0, "warm second pass reindexes 0 files")

    // Incremental: editing one file reindexes just it.
    try? "# Hello\nedited body".write(to: vault.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    try? index.reindex(paths: ["a.md"], vault: vault)
    let hitsAfterEdit = (try? index.search("edited")) ?? []
    expectEqual(hitsAfterEdit.first?.path, "a.md", "incremental reindex picks up the edit")
    expect(((try? index.search("first")) ?? []).isEmpty, "old body is gone from the index")

    // reindex(paths:) of a missing file removes it; remove(paths:) works directly.
    try? fm.removeItem(at: vault.appendingPathComponent("Sub/b.md"))
    try? index.reindex(paths: ["Sub/b.md"], vault: vault)
    expectEqual(try? index.indexedCount(), 1, "missing file dropped on incremental pass")
    try? index.remove(paths: ["a.md"])
    expectEqual(try? index.indexedCount(), 0, "explicit remove empties the index")
}

func searchQueryChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-sq-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "운동 기록\n오늘은 헬스운동화를 신고 턱걸이를 했다. 운동 최고."
        .write(to: vault.appendingPathComponent("건강.md"), atomically: true, encoding: .utf8)
    try? "# Reading list\nGood code Bad code is a great book."
        .write(to: vault.appendingPathComponent("books.md"), atomically: true, encoding: .utf8)

    guard let index = try? SearchIndex(vaultRoot: vault) else { expect(false, "index opens"); return }
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    try? index.reindexAll(vault: vault)

    // Korean sub-word match via trigram: "운동화" inside "헬스운동화".
    let korean = (try? index.search("운동화")) ?? []
    expectEqual(korean.first?.path, "건강.md", "Korean sub-word match")
    expect(korean.first?.snippet.contains("헬스운동화") ?? false, "snippet shows match context")
    expect(!(korean.first?.matchRanges.isEmpty ?? true), "highlight ranges present")
    if let hit = korean.first, let offset = hit.firstMatchOffset {
        let body = try! String(contentsOf: vault.appendingPathComponent("건강.md"), encoding: .utf8)
        let ns = body as NSString
        expectEqual(ns.substring(with: NSRange(location: offset, length: 3)), "운동화", "offset lands on the match")
    } else { expect(false, "firstMatchOffset present") }

    // English match + bm25 ordering sanity.
    let english = (try? index.search("great book")) ?? []
    expectEqual(english.first?.path, "books.md", "English phrase match")

    // Short query (< 3 chars) takes the LIKE fallback — Korean 2-char included.
    let short = (try? index.search("턱걸")) ?? []
    expectEqual(short.first?.path, "건강.md", "2-char Korean query via LIKE fallback")

    // Title match works (filename base is the title).
    let title = (try? index.search("books")) ?? []
    expectEqual(title.first?.path, "books.md", "title match")

    // No hits / blank query.
    expect(((try? index.search("zzqqxx")) ?? []).isEmpty, "no false hits")
    expect(((try? index.search("  ")) ?? []).isEmpty, "blank query → empty")

    // Surrogate-pair safety: a 💯 (supplementary plane) sits exactly where the
    // ±40 snippet window would cut; the snippet must stay a valid string.
    let pad = String(repeating: "x", count: 39)
    try? (pad + "💯 unique-needle here").write(to: vault.appendingPathComponent("emoji.md"),
                                               atomically: true, encoding: .utf8)
    try? index.reindex(paths: ["emoji.md"], vault: vault)
    let emoji = (try? index.search("unique-needle")) ?? []
    expectEqual(emoji.first?.path, "emoji.md", "match next to an emoji boundary")
    let snip = emoji.first?.snippet ?? ""
    expect(!snip.unicodeScalars.contains { $0.value == 0xFFFD }, "snippet has no replacement chars")
    expect(snip.contains("unique-needle"), "snippet contains the match")
}

func appStateSearchChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-as-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "# Note\nxylophone serenade".write(to: vault.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)

    let state = AppState(defaults: UserDefaults(suiteName: "mk-as-\(UUID().uuidString)")!)
    state.openVault(at: vault)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    expect(state.searchIndex != nil, "search index opens with the vault")

    // openVault schedules a background reindex; pump until searchable.
    var hits: [SearchHit] = []
    let deadline = Date().addingTimeInterval(5)
    while hits.isEmpty && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hits = (try? state.searchIndex?.search("xylophone")) ?? []
    }
    expectEqual(hits.first?.path, "n.md", "vault open indexes existing notes")

    // Saving an edit reindexes incrementally (via scheduleReindex).
    state.open(state.files[0], newTab: true)
    state.activeText = "# Note\nquixotic melody"
    state.save()
    var edited: [SearchHit] = []
    let deadline2 = Date().addingTimeInterval(5)
    while edited.isEmpty && Date() < deadline2 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        edited = (try? state.searchIndex?.search("quixotic")) ?? []
    }
    expectEqual(edited.first?.path, "n.md", "save reindexes the note")
}

func linkTableChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-lt-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault.appendingPathComponent("Projects"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "# Plan\ncontent".write(to: vault.appendingPathComponent("Projects/Plan.md"), atomically: true, encoding: .utf8)
    try? "허브 노트입니다. [[Plan]] 참고, 그리고 [[Plan|계획]]도."
        .write(to: vault.appendingPathComponent("Hub.md"), atomically: true, encoding: .utf8)
    try? "경로로 링크: [전체](Projects/Plan.md)"
        .write(to: vault.appendingPathComponent("Path.md"), atomically: true, encoding: .utf8)
    try? "무관한 노트".write(to: vault.appendingPathComponent("Other.md"), atomically: true, encoding: .utf8)

    guard let index = try? SearchIndex(vaultRoot: vault) else { expect(false, "index opens"); return }
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    try? index.reindexAll(vault: vault)

    // Backlinks of Projects/Plan.md: Hub (wikilink, filename-base) + Path (full path md link).
    let back = (try? index.backlinks(of: "Projects/Plan.md")) ?? []
    expectEqual(back.map(\.sourcePath).sorted(), ["Hub.md", "Path.md"], "filename-base + full-path links found")
    expect(!back.contains { $0.sourcePath == "Other.md" }, "unrelated note absent")

    // One row per source (Hub links twice), snippet shows context with ranges.
    let hub = back.first { $0.sourcePath == "Hub.md" }
    expectEqual(hub?.sourceTitle, "Hub", "source title is filename base")
    expect(hub?.snippet.contains("[[Plan]]") ?? false, "snippet shows the link context")
    expect(!(hub?.matchRanges.isEmpty ?? true), "snippet highlight ranges present")

    // Editing the source away removes the backlink; deleting the file too.
    try? "이제 링크 없음".write(to: vault.appendingPathComponent("Hub.md"), atomically: true, encoding: .utf8)
    try? index.reindex(paths: ["Hub.md"], vault: vault)
    let afterEdit = (try? index.backlinks(of: "Projects/Plan.md")) ?? []
    expect(!afterEdit.contains { $0.sourcePath == "Hub.md" }, "edited-away link gone")
    try? index.remove(paths: ["Path.md"])
    let afterRemove = (try? index.backlinks(of: "Projects/Plan.md")) ?? []
    expect(afterRemove.isEmpty, "removed source drops its links")
}

func dataviewExecChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-dv-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault.appendingPathComponent("Projects"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "---\nstatus: active\npriority: 3\n---\n#proj alpha".write(to: vault.appendingPathComponent("Projects/Alpha.md"), atomically: true, encoding: .utf8)
    try? "---\nstatus: done\npriority: 10\n---\n#proj beta".write(to: vault.appendingPathComponent("Projects/Beta.md"), atomically: true, encoding: .utf8)
    try? "---\nstatus: active\npriority: 2\n---\n#proj 감마".write(to: vault.appendingPathComponent("Gamma.md"), atomically: true, encoding: .utf8)
    try? "no tag, no fields".write(to: vault.appendingPathComponent("Plain.md"), atomically: true, encoding: .utf8)

    guard let index = try? SearchIndex(vaultRoot: vault) else { expect(false, "index opens"); return }
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    try? index.reindexAll(vault: vault)

    // TABLE … FROM #tag WHERE … SORT … (numeric compare + desc).
    let q = DataviewQuery.parse("TABLE status, priority FROM #proj WHERE priority >= 2 AND status != \"done\" SORT priority DESC")!
    let rows = (try? index.dataview(q)) ?? []
    expectEqual(rows.map(\.title), ["Alpha", "Gamma"], "filtered + numeric sort desc")
    expectEqual(rows.first?.values, ["active", "3"], "column values aligned")

    // Folder source.
    let folder = DataviewQuery.parse("LIST FROM \"Projects\"")!
    expectEqual((try? index.dataview(folder))?.map(\.title).sorted(), ["Alpha", "Beta"], "folder source")

    // All source + missing field ⇒ condition false.
    let all = DataviewQuery.parse("TABLE status WHERE status = \"active\"")!
    expectEqual((try? index.dataview(all))?.count, 2, "missing-field notes excluded")

    // Built-ins: sort by file.mtime works; file.name column resolves.
    let builtin = DataviewQuery.parse("TABLE file.name FROM #proj SORT file.mtime ASC")!
    let b = (try? index.dataview(builtin)) ?? []
    expectEqual(b.count, 3, "builtin query returns all tagged")
    expectEqual(b.first?.values.first ?? nil, b.first?.title, "file.name column mirrors title")

    // Editing away the tag drops the note from results.
    try? "no more tag".write(to: vault.appendingPathComponent("Gamma.md"), atomically: true, encoding: .utf8)
    try? index.reindex(paths: ["Gamma.md"], vault: vault)
    let after = (try? index.dataview(DataviewQuery.parse("LIST FROM #proj")!)) ?? []
    expect(!after.contains { $0.title == "Gamma" }, "reindex removes stale tag rows")
}

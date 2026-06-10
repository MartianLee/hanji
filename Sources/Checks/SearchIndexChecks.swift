import Foundation
import MKSearchKit

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

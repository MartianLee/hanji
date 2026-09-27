import Foundation
import MKSearchKit

/// Korean text in decomposed form (NFD — what Finder and many sync tools write
/// for file names) must be found by the precomposed text you type (NFC), and
/// links between the two forms must connect.
func searchNormalizationChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-nfd-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)); try? fm.removeItem(at: vault) }
    let nfdName = "회의록".decomposedStringWithCanonicalMapping
    expect(nfdName.unicodeScalars.count > "회의록".unicodeScalars.count, "setup: the NFD name really is decomposed")
    try? "안건 정리 #회의".decomposedStringWithCanonicalMapping
        .write(to: vault.appendingPathComponent(nfdName + ".md"), atomically: true, encoding: .utf8)
    try? "see [[회의록]]".write(to: vault.appendingPathComponent("links.md"), atomically: true, encoding: .utf8)

    guard let index = try? SearchIndex(vaultRoot: vault), (try? index.reindexAll(vault: vault)) != nil else {
        expect(false, "index opens"); return
    }
    let titleHits = (try? index.search("회의록")) ?? []
    expect(titleHits.contains { $0.title == "회의록" || $0.path.hasPrefix(nfdName) }, "an NFD file name is found by typed Korean")
    expect(!((try? index.search("안건")) ?? []).isEmpty, "NFD body text is found (2-char query)")
    expect(!((try? index.search("안건 정리")) ?? []).isEmpty, "NFD body text is found (FTS query)")
    expect(!((try? index.search("#회의")) ?? []).isEmpty, "an NFD tag is found")
    let backlinks = (try? index.backlinks(of: nfdName + ".md")) ?? []
    expectEqual(backlinks.map(\.sourcePath), ["links.md"], "a typed [[회의록]] links to the NFD-named note")
}

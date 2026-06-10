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

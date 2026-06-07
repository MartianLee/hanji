import Foundation
import VaultKit

func vaultChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-vault-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    try? "x".write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
    try? "x".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    try? "x".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

    let vault = Vault(root: root)
    let names = (try? vault.markdownFiles())?.map(\.name) ?? []
    expectEqual(names, ["a.md", "b.md"], "markdownFiles finds only .md, sorted")

    let file = MarkdownFile(url: root.appendingPathComponent("a.md"))
    try? vault.write("new content", to: file)
    expectEqual((try? vault.read(file)) ?? "", "new content", "write then read round-trips")
}

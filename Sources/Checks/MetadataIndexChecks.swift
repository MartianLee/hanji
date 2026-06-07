import Foundation
import VaultKit

func metadataIndexChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-idx-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    try? "# Hello\nbody".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    try? "no heading".write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

    let index = (try? MetadataIndex.build(from: Vault(root: root))) ?? MetadataIndex()
    expectEqual(index.notes.count, 2, "index has 2 notes")
    expectEqual(index.note(forRelativePath: "a.md")?.title ?? "", "Hello", "title from H1")
    expectEqual(index.note(forRelativePath: "b.md")?.title ?? "", "b", "title falls back to filename")
}

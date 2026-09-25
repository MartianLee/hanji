import Foundation
import VaultKit

/// Vault.write is the one path every save takes, so it must work for a
/// symlinked note and never leave its temp file behind when it fails.
func vaultWriteChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-write-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let vault = Vault(root: root)
    func leftovers() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.contains(".tmp-") }
    }

    // A note that is a symlink saves through to its target and stays a symlink.
    let real = root.appendingPathComponent("real.md")
    let link = root.appendingPathComponent("link.md")
    try? "old".write(to: real, atomically: true, encoding: .utf8)
    try? fm.createSymbolicLink(at: link, withDestinationURL: real)
    do {
        try vault.write("new", to: MarkdownFile(url: link))
        expect(true, "writing through a symlinked note succeeds")
    } catch { expect(false, "writing through a symlinked note succeeds (\(error))") }
    expectEqual(try? String(contentsOf: real, encoding: .utf8), "new", "the symlink's target got the text")
    expectEqual((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil, true, "the note is still a symlink")
    expectEqual(leftovers(), [], "no temp file left after a symlinked save")

    // A write that fails (here: the note is locked) throws and cleans up.
    let locked = root.appendingPathComponent("locked.md")
    try? "keep".write(to: locked, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.immutable: true], ofItemAtPath: locked.path)
    defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
    var threw = false
    do { try vault.write("lost?", to: MarkdownFile(url: locked)) } catch { threw = true }
    expect(threw, "a failed save throws instead of pretending")
    expectEqual(try? String(contentsOf: locked, encoding: .utf8), "keep", "the locked note is untouched")
    expectEqual(leftovers(), [], "no temp file left after a failed save")
}

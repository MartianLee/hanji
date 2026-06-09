import Foundation
import VaultKit

func vaultTreeChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mk-tree-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try? fm.createDirectory(at: root.appendingPathComponent("B-folder/inner"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: root.appendingPathComponent("a-empty"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    try? "x".write(to: root.appendingPathComponent("zeta.md"), atomically: true, encoding: .utf8)
    try? "x".write(to: root.appendingPathComponent("Alpha.md"), atomically: true, encoding: .utf8)
    try? "x".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
    try? "x".write(to: root.appendingPathComponent("B-folder/inner/deep.md"), atomically: true, encoding: .utf8)

    let tree = (try? Vault(root: root).tree()) ?? []
    expectEqual(tree.map(\.name), ["a-empty", "B-folder", "Alpha.md", "zeta.md"],
                "folders first, case-insensitive sort; hidden + non-md skipped")
    expect(tree[0].isDirectory && (tree[0].children?.isEmpty ?? false), "empty folder kept with empty children")
    let bFolder = tree[1]
    expectEqual(bFolder.children?.first?.name, "inner", "nested folder present")
    expectEqual(bFolder.children?.first?.children?.first?.name, "deep.md", "nested file present")
    expect(tree[2].children == nil, "file is a leaf (nil children)")
}

func vaultOpsChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mk-ops-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let vault = Vault(root: root)

    // createNote: default name + auto-suffix on collision.
    let n1 = try? vault.createNote()
    expectEqual(n1?.lastPathComponent, "Untitled.md", "default note name")
    let n2 = try? vault.createNote()
    expectEqual(n2?.lastPathComponent, "Untitled 1.md", "collision auto-suffix")

    // createFolder + named note inside it.
    let f1 = try? vault.createFolder()
    expectEqual(f1?.lastPathComponent, "Untitled", "default folder name (no extension)")
    let n3 = try? vault.createNote(inFolder: f1, name: "Daily log")
    expectEqual(n3?.lastPathComponent, "Daily log.md", "named note gets .md")
    expect(fm.fileExists(atPath: root.appendingPathComponent("Untitled/Daily log.md").path), "created inside folder")

    // rename: normalizes .md, same parent; collision/empty throw.
    let renamed = try? vault.rename(n3!, to: "Journal")
    expectEqual(renamed?.lastPathComponent, "Journal.md", "rename normalizes .md")
    expect(fm.fileExists(atPath: root.appendingPathComponent("Untitled/Journal.md").path), "renamed on disk")
    var collided = false
    do { _ = try vault.rename(n1!, to: "Untitled 1") } catch { collided = true }
    expect(collided, "rename collision throws")
    var emptied = false
    do { _ = try vault.rename(n1!, to: "  ") } catch { emptied = true }
    expect(emptied, "empty rename throws")

    // delete → Trash: gone from the vault (recoverable, not permanent).
    try? vault.delete(n2!)
    expect(!fm.fileExists(atPath: n2!.path), "deleted note gone from vault")
    try? vault.delete(f1!)
    expect(!fm.fileExists(atPath: f1!.path), "deleted folder gone from vault")
}

func vaultMoveChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mk-move-\(UUID().uuidString)")
    try? fm.createDirectory(at: root.appendingPathComponent("Dest"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: root.appendingPathComponent("Outer/Inner"), withIntermediateDirectories: true)
    try? "x".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(at: root) }
    let vault = Vault(root: root)
    let dest = root.appendingPathComponent("Dest")

    // Move a file into a folder.
    let moved = try? vault.move(root.appendingPathComponent("note.md"), into: dest)
    expectEqual(moved?.path, dest.appendingPathComponent("note.md").path, "file moved into folder")
    expect(fm.fileExists(atPath: dest.appendingPathComponent("note.md").path), "moved file on disk")

    // Same-parent move is a no-op.
    let same = try? vault.move(dest.appendingPathComponent("note.md"), into: dest)
    expectEqual(same?.path, dest.appendingPathComponent("note.md").path, "same-parent move is a no-op")

    // Move a folder into another folder.
    let outerMoved = try? vault.move(root.appendingPathComponent("Outer"), into: dest)
    expect(outerMoved != nil && fm.fileExists(atPath: dest.appendingPathComponent("Outer/Inner").path),
           "folder moved with its contents")

    // A folder cannot move into itself or a descendant.
    var selfMove = false
    do { _ = try vault.move(dest.appendingPathComponent("Outer"), into: dest.appendingPathComponent("Outer/Inner")) }
    catch { selfMove = true }
    expect(selfMove, "folder into own descendant throws")

    // Name collision in the destination throws.
    try? "y".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
    var collided = false
    do { _ = try vault.move(root.appendingPathComponent("note.md"), into: dest) } catch { collided = true }
    expect(collided, "move collision throws")
}

func vaultWatcherChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mk-watch-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    var fired = false
    let watcher = VaultWatcher(root: root) { fired = true }
    // Let the FSEvents stream warm up, then simulate an external edit.
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    try? "x".write(to: root.appendingPathComponent("ext.md"), atomically: true, encoding: .utf8)
    let deadline = Date().addingTimeInterval(5)
    while !fired && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    watcher.stop()
    expect(fired, "watcher fires after external file creation")
}

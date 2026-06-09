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

func vaultSortChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mk-sort-\(UUID().uuidString)")
    try? fm.createDirectory(at: root.appendingPathComponent("Zf"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: root.appendingPathComponent("Af"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let vault = Vault(root: root)

    func make(_ name: String, modified: Date, created: Date) {
        let url = root.appendingPathComponent(name)
        try? "x".write(to: url, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: url.path)
    }
    // Note: APFS clamps creationDate to ≤ modificationDate, so each fixture keeps
    // created ≤ modified while the two orderings still differ.
    func t(_ n: Double) -> Date { Date(timeIntervalSince1970: n * 1_000_000) }
    make("alpha.md", modified: t(5), created: t(0))   // newest modified, oldest created
    make("beta.md",  modified: t(3), created: t(2))
    make("gamma.md", modified: t(4), created: t(4))   // newest created

    func fileNames(_ sort: TreeSort) -> [String] {
        ((try? vault.tree(sort: sort)) ?? []).filter { !$0.isDirectory }.map(\.name)
    }
    expectEqual(fileNames(.nameAsc), ["alpha.md", "beta.md", "gamma.md"], "name A→Z")
    expectEqual(fileNames(.nameDesc), ["gamma.md", "beta.md", "alpha.md"], "name Z→A")
    expectEqual(fileNames(.modifiedDesc), ["alpha.md", "gamma.md", "beta.md"], "modified new→old")
    expectEqual(fileNames(.modifiedAsc), ["beta.md", "gamma.md", "alpha.md"], "modified old→new")
    expectEqual(fileNames(.createdDesc), ["gamma.md", "beta.md", "alpha.md"], "created new→old")
    expectEqual(fileNames(.createdAsc), ["alpha.md", "beta.md", "gamma.md"], "created old→new")

    // Folders always come first, ordered by name (direction follows name sorts only).
    let folders = ((try? vault.tree(sort: .modifiedDesc)) ?? []).prefix(2).map(\.name)
    expectEqual(Array(folders), ["Af", "Zf"], "folders first, by name, under time sorts")
    let foldersDesc = ((try? vault.tree(sort: .nameDesc)) ?? []).prefix(2).map(\.name)
    expectEqual(Array(foldersDesc), ["Zf", "Af"], "folder order follows name direction")
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

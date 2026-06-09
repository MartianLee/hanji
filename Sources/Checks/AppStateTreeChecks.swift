import Foundation
import AppCore
import VaultKit

func appStateTreeChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mk-astree-\(UUID().uuidString)")
    try? fm.createDirectory(at: root.appendingPathComponent("Sub"), withIntermediateDirectories: true)
    try? "# A".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(at: root) }

    let state = AppState(defaults: UserDefaults(suiteName: "mk-ast-\(UUID().uuidString)")!)
    state.openVault(at: root)
    expectEqual(state.tree.map(\.name), ["Sub", "a.md"], "tree built on openVault")

    // New note in a subfolder is created and opened.
    let sub = root.appendingPathComponent("Sub")
    let created = state.newNote(inFolder: sub)
    expectEqual(created?.lastPathComponent, "Untitled.md", "new note default name")
    expectEqual(state.selectedFile?.url.standardizedFileURL, created?.standardizedFileURL, "new note opened")
    let subChildren: [FileNode] = state.tree.first(where: { $0.name == "Sub" })?.children ?? []
    expect(subChildren.contains(where: { $0.name == "Untitled.md" }), "tree shows the new note")

    // Renaming the open note follows the selection.
    _ = try? state.rename(created!, to: "Renamed")
    expectEqual(state.selectedFile?.url.lastPathComponent, "Renamed.md", "open note rename follows selection")

    // Moving the open note follows the selection.
    let movedURL = try? state.move(state.selectedFile!.url, into: root)
    expectEqual(state.selectedFile?.url.standardizedFileURL, movedURL?.standardizedFileURL, "open note move follows selection")
    _ = try? state.move(movedURL!, into: sub)   // put it back for the delete step

    // New folder appears in the tree.
    let folder = state.newFolder(inFolder: nil)
    let folderName = folder?.lastPathComponent ?? ""
    let folderInTree = state.tree.contains(where: { $0.name == folderName && $0.isDirectory })
    expect(folder != nil && folderInTree, "new folder in tree")

    // Deleting the open note clears the editor and the tree entry.
    state.delete(state.selectedFile!.url)
    expect(state.selectedFile == nil && state.activeText.isEmpty, "deleting open note clears editor")
    let subAfter: [FileNode] = state.tree.first(where: { $0.name == "Sub" })?.children ?? []
    expect(!subAfter.contains(where: { $0.name == "Renamed.md" }), "tree updated after delete")
}

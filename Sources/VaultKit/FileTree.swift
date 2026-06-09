import Foundation

/// A node in the vault's sidebar file tree: folders (with children, possibly
/// empty) and markdown files (leaves, `children == nil`).
public struct FileNode: Identifiable, Hashable {
    public let url: URL
    public let isDirectory: Bool
    public var children: [FileNode]?

    public init(url: URL, isDirectory: Bool, children: [FileNode]?) {
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
}

public enum VaultError: Error, LocalizedError {
    case invalidName
    case nameTaken(String)
    case cannotMoveIntoItself

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Name cannot be empty."
        case .nameTaken(let name): return "\u{201C}\(name)\u{201D} already exists here."
        case .cannotMoveIntoItself: return "A folder can\u{2019}t be moved into itself."
        }
    }
}

extension Vault {
    /// The vault's folder + `.md` hierarchy: folders first (empty ones kept),
    /// case-insensitive alphabetical, hidden entries (incl. `.obsidian`) and
    /// non-markdown files skipped.
    public func tree() throws -> [FileNode] {
        try nodes(in: root)
    }

    private func nodes(in dir: URL) throws -> [FileNode] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: dir,
                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        var out: [FileNode] = []
        for url in entries {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                out.append(FileNode(url: url, isDirectory: true, children: try nodes(in: url)))
            } else if url.pathExtension.lowercased() == "md" {
                out.append(FileNode(url: url, isDirectory: false, children: nil))
            }
        }
        return out.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - File management

    /// Create an empty note (default "Untitled", auto-suffixed on collision) and
    /// return its URL. `name` may omit the `.md` extension.
    @discardableResult
    public func createNote(inFolder folder: URL? = nil, name: String? = nil) throws -> URL {
        let dir = folder ?? root
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var base = (name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        if base.lowercased().hasSuffix(".md") { base = String(base.dropLast(3)) }
        let url = availableURL(in: dir, base: base, ext: "md")
        try write("", to: MarkdownFile(url: url))
        return url
    }

    /// Create a folder (default "Untitled", auto-suffixed) and return its URL.
    @discardableResult
    public func createFolder(inFolder folder: URL? = nil, name: String? = nil) throws -> URL {
        let dir = folder ?? root
        let base = (name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        let url = availableURL(in: dir, base: base, ext: nil)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Rename within the same parent. Files keep/normalize their `.md` extension.
    /// Throws `VaultError.nameTaken` on collision and `.invalidName` when empty.
    @discardableResult
    public func rename(_ url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw VaultError.invalidName }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        var finalName = trimmed
        if !isDir && !finalName.lowercased().hasSuffix(".md") { finalName += ".md" }
        let dest = url.deletingLastPathComponent().appendingPathComponent(finalName)
        if dest.standardizedFileURL == url.standardizedFileURL { return url }
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw VaultError.nameTaken(finalName) }
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    /// Move a note or folder to the Trash (recoverable — never a permanent delete).
    public func delete(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Move a note or folder into another folder (same name kept). Same-parent
    /// moves are a no-op; moving a folder into itself/a descendant and name
    /// collisions throw.
    @discardableResult
    public func move(_ url: URL, into folder: URL) throws -> URL {
        let src = url.standardizedFileURL
        let dstDir = folder.standardizedFileURL
        if src.deletingLastPathComponent().path == dstDir.path { return url }
        if dstDir.path == src.path || dstDir.path.hasPrefix(src.path + "/") {
            throw VaultError.cannotMoveIntoItself
        }
        let dest = dstDir.appendingPathComponent(src.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw VaultError.nameTaken(src.lastPathComponent)
        }
        try FileManager.default.moveItem(at: src, to: dest)
        return dest
    }

    private func availableURL(in dir: URL, base: String, ext: String?) -> URL {
        let fm = FileManager.default
        func candidate(_ i: Int) -> URL {
            let name = i == 0 ? base : "\(base) \(i)"
            let url = dir.appendingPathComponent(name)
            return ext.map { url.appendingPathExtension($0) } ?? url
        }
        var i = 0
        while fm.fileExists(atPath: candidate(i).path) { i += 1 }
        return candidate(i)
    }
}

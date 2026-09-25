import Foundation
import MarkdownCore

public struct MarkdownFile: Identifiable, Hashable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public var id: URL { url }
    public var name: String { url.lastPathComponent }
}

public struct Vault {
    public let root: URL
    public init(root: URL) { self.root = root }

    /// All `.md` files under root, recursively, sorted by full path.
    public func markdownFiles() throws -> [MarkdownFile] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [MarkdownFile] = []
        for case let url as URL in en where url.pathExtension.lowercased() == "md" {
            out.append(MarkdownFile(url: url))
        }
        return out.sorted { $0.url.path < $1.url.path }
    }

    public func read(_ file: MarkdownFile) throws -> String {
        try String(contentsOf: file.url, encoding: .utf8)
    }

    /// Atomic write: write a temp file in the same directory, then replace.
    /// A symlinked note is written through to its target (replacing the link
    /// itself fails), and the temp file never outlives a failed write.
    public func write(_ text: String, to file: MarkdownFile) throws {
        let fm = FileManager.default
        let target = file.url.resolvingSymlinksInPath()
        let dir = target.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(target.lastPathComponent).tmp-\(UUID().uuidString)")
        try Data(text.utf8).write(to: tmp)
        do {
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: target)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}

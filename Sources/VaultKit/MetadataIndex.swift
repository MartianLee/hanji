import Foundation
import MarkdownCore

public struct NoteMeta: Equatable {
    public let path: String     // relative to vault root
    public let title: String
    public let mtime: Date
    public let tags: [String]
}

public struct MetadataIndex {
    public private(set) var notes: [NoteMeta]
    public init(notes: [NoteMeta] = []) { self.notes = notes }

    /// Build an index by reading each file's title (first H1, else filename).
    public static func build(from vault: Vault) throws -> MetadataIndex {
        let fm = FileManager.default
        var metas: [NoteMeta] = []
        for f in try vault.markdownFiles() {
            let text = (try? vault.read(f)) ?? ""
            let fallback = f.url.deletingPathExtension().lastPathComponent
            let title = TitleExtractor.title(fromMarkdown: text, fallback: fallback)
            let attrs = try? fm.attributesOfItem(atPath: f.url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            metas.append(NoteMeta(path: relativePath(of: f.url, under: vault.root),
                                  title: title, mtime: mtime, tags: Tags.extract(from: text)))
        }
        return MetadataIndex(notes: metas)
    }

    public func note(forRelativePath path: String) -> NoteMeta? {
        notes.first { $0.path == path }
    }

    public func notes(withTag tag: String) -> [NoteMeta] {
        notes.filter { $0.tags.contains(tag) }
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let r = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p.hasPrefix(r + "/") { return String(p.dropFirst(r.count + 1)) }
        return url.lastPathComponent
    }
}

import Foundation
import CryptoKit
import GRDB

/// Persistent per-vault full-text index (SQLite + FTS5 trigram via GRDB).
/// Lives in Application Support — outside the vault, so index writes never
/// pollute the vault or wake the vault's FSEvents watcher.
public final class SearchIndex {
    let dbQueue: DatabaseQueue

    public init(vaultRoot: URL) throws {
        let url = Self.indexFileURL(forVault: vaultRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "note") { t in
                t.column("path", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("mtime", .double).notNull()
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE note_fts USING fts5(
                  path UNINDEXED, title, body, tokenize='trigram'
                )
                """)
        }
        try migrator.migrate(dbQueue)
    }

    /// `~/Library/Application Support/hanji/index/<sha256-of-vault-path>.db`
    public static func indexFileURL(forVault root: URL) -> URL {
        let canonical = root.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support.appendingPathComponent("hanji/index/\(hex).db")
    }

    // MARK: - Indexing

    /// Index every `.md` under the vault, skipping files whose mtime is
    /// unchanged. Returns the number of files (re)indexed.
    @discardableResult
    public func reindexAll(vault root: URL) throws -> Int {
        let fm = FileManager.default
        var seen: Set<String> = []
        var changed = 0
        // One read up front instead of a DB roundtrip per file.
        let storedMtimes: [String: Double] = try dbQueue.read { db in
            var out: [String: Double] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT path, mtime FROM note") {
                out[row["path"]] = row["mtime"]
            }
            return out
        }
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                  options: [.skipsHiddenFiles]) {
            for case let url as URL in en where url.pathExtension.lowercased() == "md" {
                let path = relativePath(of: url, under: root)
                seen.insert(path)
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                if let stored = storedMtimes[path], abs(stored - mtime) < 0.001 { continue }
                try upsert(path: path, url: url, mtime: mtime)
                changed += 1
            }
        }
        // Drop rows for files that no longer exist.
        let indexed = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM note")
        }
        let gone = indexed.filter { !seen.contains($0) }
        if !gone.isEmpty { try remove(paths: gone) }
        return changed
    }

    /// Incrementally (re)index specific vault-relative paths; missing files are removed.
    public func reindex(paths: [String], vault root: URL) throws {
        for path in paths {
            let url = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                try remove(paths: [path])
                continue
            }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            try upsert(path: path, url: url, mtime: mtime)
        }
    }

    public func remove(paths: [String]) throws {
        try dbQueue.write { db in
            for path in paths {
                try db.execute(sql: "DELETE FROM note WHERE path = ?", arguments: [path])
                try db.execute(sql: "DELETE FROM note_fts WHERE path = ?", arguments: [path])
            }
        }
    }

    public func indexedCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? 0
        }
    }

    private func upsert(path: String, url: URL, mtime: Double) throws {
        let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let title = url.deletingPathExtension().lastPathComponent
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO note (path, title, mtime) VALUES (?, ?, ?)",
                           arguments: [path, title, mtime])
            try db.execute(sql: "DELETE FROM note_fts WHERE path = ?", arguments: [path])
            try db.execute(sql: "INSERT INTO note_fts (path, title, body) VALUES (?, ?, ?)",
                           arguments: [path, title, body])
        }
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let r = root.standardizedFileURL.path + "/"
        let u = url.standardizedFileURL.path
        return u.hasPrefix(r) ? String(u.dropFirst(r.count)) : url.lastPathComponent
    }

    // MARK: - Search

    /// Full-text search. Queries of 3+ characters use FTS5 trigram MATCH with
    /// bm25 ranking; shorter ones fall back to LIKE (substring) so 1–2-char
    /// Korean queries still work.
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        struct Stored { let path: String; let title: String; let body: String; let score: Double }
        let stored: [Stored]
        if q.count >= 3 {
            let match = "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            stored = try dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT path, title, body, bm25(note_fts) AS score
                    FROM note_fts WHERE note_fts MATCH ?
                    ORDER BY score LIMIT ?
                    """, arguments: [match, limit])
                .map { Stored(path: $0["path"], title: $0["title"], body: $0["body"], score: $0["score"]) }
            }
        } else {
            // Deliberate full scan: FTS5 trigram cannot MATCH patterns shorter
            // than 3 chars, and vault sizes keep a LIKE scan cheap. Do not
            // "optimize" this to MATCH — it errors on short queries.
            let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let like = "%\(escaped)%"
            stored = try dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT path, title, body, 0.0 AS score
                    FROM note_fts
                    WHERE title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\'
                    ORDER BY (title LIKE ? ESCAPE '\\') DESC, path LIMIT ?
                    """, arguments: [like, like, like, limit])
                .map { Stored(path: $0["path"], title: $0["title"], body: $0["body"], score: $0["score"]) }
            }
        }
        return stored.map { SearchHit.make(path: $0.path, title: $0.title, body: $0.body,
                                           query: q, score: $0.score) }
    }
}

import Foundation
import CryptoKit
import GRDB
import MarkdownCore

/// Persistent per-vault full-text index (SQLite + FTS5 trigram via GRDB).
/// Lives in Application Support — outside the vault, so index writes never
/// pollute the vault or wake the vault's FSEvents watcher.
public final class SearchIndex {
    private let dbQueue: DatabaseQueue
    /// Serializes whole-vault reindex passes: a background pass (AppState's
    /// searchQueue) and a direct call must not interleave their mtime-skip
    /// reads/writes, or a just-saved note can be left unindexed.
    private let reindexLock = NSLock()

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
        // ⚠️ Never edit an applied migration's body — GRDB tracks identifiers
        // only and silently skips re-runs. Repairs go in a NEW migration.
        migrator.registerMigration("v2") { db in
            try db.create(table: "link") { t in
                t.column("source", .text).notNull()    // vault-relative path of the linking note
                t.column("target", .text).notNull()    // normalized: lowercased, .md stripped
                t.column("offset", .integer).notNull() // UTF-16 offset of the link in source body
            }
            try db.create(indexOn: "link", columns: ["target"])
            // Force a full re-derive on the next reindex pass: links are
            // extracted during upsert, and mtime-skip would otherwise leave
            // pre-v2 rows without link data forever.
            try db.execute(sql: "DELETE FROM note")
            try db.execute(sql: "DELETE FROM note_fts")
        }
        migrator.registerMigration("v3") { db in
            try db.create(table: "tag") { t in
                t.column("path", .text).notNull()
                t.column("tag", .text).notNull()      // lowercased, no '#'
            }
            try db.create(table: "field") { t in
                t.column("path", .text).notNull()
                t.column("key", .text).notNull()      // lowercased
                t.column("value", .text).notNull()
            }
            try db.create(indexOn: "tag", columns: ["tag"])
            try db.create(indexOn: "field", columns: ["key"])
            // Backfill: force re-derive (mtime-skip would starve the new tables).
            try db.execute(sql: "DELETE FROM note")
            try db.execute(sql: "DELETE FROM note_fts")
        }
        migrator.registerMigration("v4") { db in
            // Re-derive everything: text is now stored NFC (so decomposed Korean
            // is searchable), and tags/links are no longer taken from code.
            for table in ["note", "note_fts", "link", "tag", "field"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
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
        reindexLock.lock()
        defer { reindexLock.unlock() }
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
                try db.execute(sql: "DELETE FROM link WHERE source = ?", arguments: [path])
                try db.execute(sql: "DELETE FROM tag WHERE path = ?", arguments: [path])
                try db.execute(sql: "DELETE FROM field WHERE path = ?", arguments: [path])
            }
        }
    }

    public func indexedCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? 0
        }
    }

    private func upsert(path: String, url: URL, mtime: Double) throws {
        // Everything searchable is stored precomposed (NFC): Finder and many sync
        // tools write decomposed (NFD) Korean, which wouldn't match what's typed.
        // `path` stays as it is on disk — it's how the file is found again.
        let body = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").precomposedStringWithCanonicalMapping
        let title = url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO note (path, title, mtime) VALUES (?, ?, ?)",
                           arguments: [path, title, mtime])
            try db.execute(sql: "DELETE FROM note_fts WHERE path = ?", arguments: [path])
            try db.execute(sql: "INSERT INTO note_fts (path, title, body) VALUES (?, ?, ?)",
                           arguments: [path, title, body])
            try db.execute(sql: "DELETE FROM link WHERE source = ?", arguments: [path])
            for ref in LinkParser.links(in: body) {
                try db.execute(sql: "INSERT INTO link (source, target, offset) VALUES (?, ?, ?)",
                               arguments: [path, Self.normalizeTarget(ref.target), ref.range.lowerBound])
            }
            try db.execute(sql: "DELETE FROM tag WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM field WHERE path = ?", arguments: [path])
            for tag in Tags.extract(from: body) {
                try db.execute(sql: "INSERT INTO tag (path, tag) VALUES (?, ?)",
                               arguments: [path, tag.lowercased()])
            }
            for (key, value) in Frontmatter.parse(body) {
                try db.execute(sql: "INSERT INTO field (path, key, value) VALUES (?, ?, ?)",
                               arguments: [path, key, value])
            }
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
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !q.isEmpty else { return [] }
        struct Stored { let path: String; let title: String; let body: String; let score: Double }
        let stored: [Stored]
        if let tag = Self.singleTag(q) {
            // Exactly one `#tag`: the notes that carry it (or a tag nested under
            // it), from the tag table — not every note whose text has the letters.
            let t = tag.lowercased()
            let nested = Self.likeEscaped(t) + "/%"
            stored = try dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT n.path AS path, n.title AS title, f.body AS body, 0.0 AS score
                    FROM tag tg
                    JOIN note n ON n.path = tg.path
                    JOIN note_fts f ON f.path = tg.path
                    WHERE tg.tag = ? OR tg.tag LIKE ? ESCAPE '\\'
                    GROUP BY n.path
                    ORDER BY n.title COLLATE NOCASE LIMIT ?
                    """, arguments: [t, nested, limit])
                .map { Stored(path: $0["path"], title: $0["title"], body: $0["body"], score: $0["score"]) }
            }
        } else if q.count >= 3 {
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

    /// `s` with LIKE's wildcards and the escape character escaped (ESCAPE '\\').
    static func likeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// The tag name when `query` is exactly one `#tag` and nothing else.
    static func singleTag(_ query: String) -> String? {
        let tags = Tags.occurrences(in: query)
        guard tags.count == 1, tags[0].range == 0..<(query as NSString).length else { return nil }
        return tags[0].name
    }

    // MARK: - Backlinks

    /// Notes whose links resolve to the note at `relativePath` (filename base
    /// or full relative path, Obsidian-style), one entry per source, with a
    /// context snippet around the first link.
    public func backlinks(of relativePath: String) throws -> [Backlink] {
        let url = URL(fileURLWithPath: "/" + relativePath)   // path math only
        let base = Self.normalizeTarget(url.deletingPathExtension().lastPathComponent)
        let full = Self.normalizeTarget(relativePath)
        let targets = base == full ? [base] : [base, full]
        let placeholders = targets.map { _ in "?" }.joined(separator: ", ")
        struct Row0 { let source: String; let title: String; let body: String; let offset: Int }
        let rows: [Row0] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.source AS source, n.title AS title, f.body AS body, MIN(l.offset) AS offset
                FROM link l
                JOIN note n ON n.path = l.source
                JOIN note_fts f ON f.path = l.source
                WHERE l.target IN (\(placeholders))
                GROUP BY l.source
                ORDER BY n.title COLLATE NOCASE
                """, arguments: StatementArguments(targets))
            .map { Row0(source: $0["source"], title: $0["title"], body: $0["body"], offset: $0["offset"]) }
        }
        return rows.map { row in
            let ns = row.body as NSString
            let loc = min(max(0, row.offset), max(0, ns.length - 1))
            let linkRange = NSRange(location: loc, length: 0)
            let (snippet, ranges) = SnippetWindow.make(body: row.body, around: linkRange,
                                                       highlight: base)
            return Backlink(sourcePath: row.source, sourceTitle: row.title,
                            snippet: snippet, matchRanges: ranges)
        }
    }

    private static func normalizeTarget(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping.lowercased()
        if t.hasSuffix(".md") { t = String(t.dropLast(3)) }
        if t.hasPrefix("./") { t = String(t.dropFirst(2)) }
        return t
    }

    // MARK: - Dataview

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Execute a parsed dataview query: source filter → WHERE → SORT.
    public func dataview(_ query: DataviewQuery.Parsed) throws -> [DataviewQuery.ResultRow] {
        struct Candidate { let path: String; let title: String; let mtime: Double; var fields: [String: String] }
        var candidates: [Candidate] = try dbQueue.read { db in
            let rows: [Row]
            switch query.source {
            case .tag(let tag):
                // A tag includes the tags nested under it, as in search.
                let t = tag.lowercased()
                rows = try Row.fetchAll(db, sql: """
                    SELECT n.path AS path, n.title AS title, n.mtime AS mtime
                    FROM note n JOIN tag t ON t.path = n.path
                    WHERE t.tag = ? OR t.tag LIKE ? ESCAPE '\\'
                    GROUP BY n.path
                    """, arguments: [t, Self.likeEscaped(t) + "/%"])
            case .folder(let raw):
                let folder = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))   // "p/" is "p"
                let escaped = folder.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                rows = try Row.fetchAll(db, sql: """
                    SELECT path, title, mtime FROM note WHERE path LIKE ? ESCAPE '\\'
                    """, arguments: [escaped + "/%"])
            case .all:
                rows = try Row.fetchAll(db, sql: "SELECT path, title, mtime FROM note")
            }
            return rows.map { Candidate(path: $0["path"], title: $0["title"], mtime: $0["mtime"], fields: [:]) }
        }
        guard !candidates.isEmpty else { return [] }

        // Scope the field read to the candidate paths so a small FROM result
        // doesn't materialize the whole vault's fields.
        let candidatePaths = candidates.map { $0.path }
        let placeholders = candidatePaths.map { _ in "?" }.joined(separator: ",")
        let fieldRows: [(String, String, String)] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT path, key, value FROM field WHERE path IN (\(placeholders))",
                             arguments: StatementArguments(candidatePaths))
                .map { ($0["path"], $0["key"], $0["value"]) }
        }
        var fieldMap: [String: [String: String]] = [:]
        for (path, key, value) in fieldRows { fieldMap[path, default: [:]][key] = value }
        for i in candidates.indices { candidates[i].fields = fieldMap[candidates[i].path] ?? [:] }

        func value(_ c: Candidate, _ key: String) -> String? {
            switch key {
            case "file.name": return c.title
            case "file.mtime": return Self.dayFormatter.string(from: Date(timeIntervalSince1970: c.mtime))
            default: return c.fields[key]
            }
        }

        let filtered = candidates.filter { c in
            query.conditions.allSatisfy { cond in
                guard let lhs = value(c, cond.field) else { return false }   // missing field ⇒ false
                if let ln = Double(lhs), let rn = Double(cond.value) {
                    switch cond.op {
                    case .eq: return ln == rn
                    case .ne: return ln != rn
                    case .lt: return ln < rn
                    case .le: return ln <= rn
                    case .gt: return ln > rn
                    case .ge: return ln >= rn
                    }
                }
                let cmp = lhs.caseInsensitiveCompare(cond.value)
                switch cond.op {
                case .eq: return cmp == .orderedSame
                case .ne: return cmp != .orderedSame
                case .lt: return cmp == .orderedAscending
                case .le: return cmp != .orderedDescending
                case .gt: return cmp == .orderedDescending
                case .ge: return cmp != .orderedAscending
                }
            }
        }

        let sortField = query.sort?.field ?? "file.name"
        let ascending = query.sort?.ascending ?? true
        func sortValue(_ c: Candidate) -> (Double?, String) {
            if sortField == "file.mtime" { return (c.mtime, "") }
            let v = value(c, sortField) ?? ""
            return (Double(v), v.lowercased())
        }
        let sorted = filtered.sorted { a, b in
            let av = sortValue(a), bv = sortValue(b)
            let comparison: ComparisonResult
            if let an = av.0, let bn = bv.0 {
                comparison = an == bn ? .orderedSame : (an < bn ? .orderedAscending : .orderedDescending)
            } else if av.1 != bv.1 {
                comparison = av.1 < bv.1 ? .orderedAscending : .orderedDescending
            } else {
                comparison = .orderedSame
            }
            if comparison == .orderedSame {
                return a.title.lowercased() < b.title.lowercased()   // stable tiebreak
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }

        return sorted.map { c in
            DataviewQuery.ResultRow(path: c.path, title: c.title,
                                    values: query.columns.map { value(c, $0) })
        }
    }
}

/// One backlink: a note whose body links to the queried note.
public struct Backlink: Identifiable {
    public let sourcePath: String
    public let sourceTitle: String
    public let snippet: String
    public let matchRanges: [Range<Int>]
    public var id: String { sourcePath }
}

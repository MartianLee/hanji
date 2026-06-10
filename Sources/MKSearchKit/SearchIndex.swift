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
}

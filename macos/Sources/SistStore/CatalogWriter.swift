import Foundation
import GRDB
import SistCore

/// Counters of one scan, persisted in the `scan` row.
public struct ScanCounters: Sendable, Hashable {
    public var walked = 0
    public var unchanged = 0
    public var parsed = 0
    public var deleted = 0
    public var errors = 0

    public init() {}
}

/// All writes a scan makes, the counterpart of the single writer in sist2's scan master.
///
/// Incremental scans work like sist2's `marked` table, without copying it: every document carries
/// the id of the last scan that saw it (`seenScanId`).
///
/// 1. `markUnchanged` stamps the files whose path, mtime and size match the catalog, and returns
///    the others, which are the only ones parsed.
/// 2. `write` upserts parse results, stamped with the current scan. A file parsed again first
///    loses its archive members: the parse emits the current ones.
/// 3. `finishScan` deletes the files on disk the scan did not see, within its scopes (archive
///    members go with their archive). Members of unchanged archives were neither seen nor parsed,
///    and are left alone.
///
/// A scan that does not finish never deletes anything; the next one simply starts over.
public struct CatalogWriter: Sendable {
    let pool: DatabasePool

    public func beginScan(sourceId: Int64) async throws -> Int64 {
        try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO scan (sourceId, startedAt, status) VALUES (?, ?, ?)",
                arguments: [sourceId, Date(), ScanStatus.running.rawValue])
            return db.lastInsertedRowID
        }
    }

    /// Returns the entries that are new or changed since they were last indexed.
    public func markUnchanged(_ entries: [FileEntry], sourceId: Int64, scanId: Int64) async throws -> [FileEntry] {
        try await pool.write { db in
            let statement = try db.cachedStatement(sql: """
                UPDATE document SET seenScanId = ?
                WHERE sourceId = ? AND path = ? AND mtime = ? AND size = ? AND parentId IS NULL
                """)
            var changed: [FileEntry] = []
            for entry in entries {
                try statement.execute(arguments: [scanId, sourceId, entry.path, entry.mtime, entry.size])
                if db.changesCount == 0 {
                    changed.append(entry)
                }
            }
            return changed
        }
    }

    /// Writes parse results in one transaction. Archive members must come after their archive.
    public func write(_ results: [ParseResult], source: Source, scanId: Int64) async throws {
        guard !results.isEmpty else { return }

        try await pool.write { db in
            let findParent = try db.cachedStatement(sql: "SELECT id FROM document WHERE sourceId = ? AND path = ?")
            let findPrevious = try db.cachedStatement(
                sql: "SELECT id FROM document WHERE sourceId = ? AND path = ? AND scanId < ?")
            let deleteMembers = try db.cachedStatement(sql: "DELETE FROM document WHERE parentId = ?")
            let upsert = try db.cachedStatement(sql: """
                INSERT INTO document (sourceId, parentId, path, directory, name, ext, mime, category, size, mtime,
                                      title, metadata, checksum, error, thumbnailCount, scanId, seenScanId)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (sourceId, path) DO UPDATE SET
                    parentId = excluded.parentId, directory = excluded.directory, name = excluded.name,
                    ext = excluded.ext, mime = excluded.mime, category = excluded.category, size = excluded.size,
                    mtime = excluded.mtime, title = excluded.title, metadata = excluded.metadata,
                    checksum = excluded.checksum, error = excluded.error, thumbnailCount = excluded.thumbnailCount,
                    scanId = excluded.scanId, seenScanId = excluded.seenScanId
                RETURNING id
                """)
            let upsertContent = try db.cachedStatement(sql: """
                INSERT INTO content (documentId, text) VALUES (?, ?)
                ON CONFLICT (documentId) DO UPDATE SET text = excluded.text
                """)
            let deleteContent = try db.cachedStatement(sql: "DELETE FROM content WHERE documentId = ?")
            let deleteFTS = try db.cachedStatement(sql: "DELETE FROM document_fts WHERE rowid = ?")
            let insertFTS = try db.cachedStatement(
                sql: "INSERT INTO document_fts (rowid, name, title, content, path) VALUES (?, ?, ?, ?, ?)")
            let deleteThumbnails = try db.cachedStatement(sql: "DELETE FROM thumbnail WHERE documentId = ?")
            let insertThumbnail = try db.cachedStatement(
                sql: "INSERT INTO thumbnail (documentId, num, data) VALUES (?, ?, ?)")

            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys

            for result in results {
                let doc = result.document
                var parentId: Int64? = nil
                var directory: String? = nil
                if let parentPath = doc.parentPath {
                    parentId = try Int64.fetchOne(findParent, arguments: [source.id, parentPath])
                } else {
                    directory = (doc.path as NSString).deletingLastPathComponent
                    // Parsed again: the members it had are replaced by the ones this parse emits
                    if let previous = try Int64.fetchOne(findPrevious, arguments: [source.id, doc.path, scanId]) {
                        try deleteMembers.execute(arguments: [previous])
                    }
                }
                let metadata = doc.metadata.isEmpty
                    ? nil : String(decoding: try encoder.encode(doc.metadata), as: UTF8.self)

                guard let id = try Int64.fetchOne(upsert, arguments: [
                    source.id, parentId, doc.path, directory, doc.name, doc.ext, doc.mime, doc.category.rawValue,
                    doc.size, doc.mtime, doc.title, metadata, doc.checksum, doc.error,
                    result.thumbnails.count, scanId, scanId,
                ]) else { continue }

                if let content = doc.content, !content.isEmpty {
                    try upsertContent.execute(arguments: [
                        id, ContentCodec.storedValue(content, compressed: result.compressedContent),
                    ])
                } else {
                    try deleteContent.execute(arguments: [id])
                }

                let text = result.indexedText ?? SearchText.indexedText(for: doc, root: source.root)
                try deleteFTS.execute(arguments: [id])
                try insertFTS.execute(arguments: [id, text.name, text.title, text.content, text.path])

                try deleteThumbnails.execute(arguments: [id])
                for (number, data) in result.thumbnails.enumerated() {
                    try insertThumbnail.execute(arguments: [id, number, data])
                }
            }
        }
    }

    /// Deletes what the scan did not see, within `scopes` (everywhere when nil), and returns the
    /// number of files deleted. A complete scan records `indexedOptions` as the options the catalog
    /// now reflects.
    @discardableResult
    public func finishScan(sourceId: Int64, scanId: Int64, counters: ScanCounters, scopes: [ScanScope]? = nil,
                           indexedOptions: ScanOptions? = nil) async throws -> Int {
        try await pool.write { db in
            var conditions = ["sourceId = ?", "parentId IS NULL", "seenScanId < ?"]
            var arguments: StatementArguments = [sourceId, scanId]
            if let scopes {
                guard !scopes.isEmpty else { return 0 }
                var alternatives: [String] = []
                for scope in scopes {
                    if scope.recursive {
                        let prefix = scope.path == "/" ? "/" : scope.path + "/"
                        alternatives.append("(path >= ? AND path < ?)")
                        _ = arguments.append(contentsOf: [prefix, String(prefix.dropLast()) + "0"])
                    } else {
                        alternatives.append("directory = ?")
                        _ = arguments.append(contentsOf: [scope.path])
                    }
                }
                conditions.append("(" + alternatives.joined(separator: " OR ") + ")")
            }
            // Members go along through the foreign key; changesCount only counts the files
            try db.execute(sql: "DELETE FROM document WHERE " + conditions.joined(separator: " AND "),
                           arguments: arguments)
            let deleted = db.changesCount

            if let root = try String.fetchOne(db, sql: "SELECT root FROM source WHERE id = ?", arguments: [sourceId]) {
                try Self.rebuildFolders(db, sourceId: sourceId, root: root)
            }

            var counters = counters
            counters.deleted = deleted
            try Self.updateScan(db, scanId: scanId, status: .completed, counters: counters)
            try db.execute(sql: "UPDATE source SET lastScanAt = ?, lastScanId = ? WHERE id = ?",
                           arguments: [Date(), scanId, sourceId])
            if let indexedOptions {
                let json = String(decoding: try JSONEncoder().encode(indexedOptions), as: UTF8.self)
                try db.execute(sql: "UPDATE source SET indexedOptions = ? WHERE id = ?", arguments: [json, sourceId])
            }
            return deleted
        }
    }

    /// Recomputes the folder table of a source from the directories of its files: every folder
    /// holding files, directly or below, with recursive counts and sizes.
    static func rebuildFolders(_ db: Database, sourceId: Int64, root: String) throws {
        try db.execute(sql: "DELETE FROM folder WHERE sourceId = ?", arguments: [sourceId])
        let rows = try Row.fetchAll(db, sql: """
            SELECT directory, count(*) AS n, coalesce(sum(size), 0) AS total FROM document
            WHERE sourceId = ? AND parentId IS NULL GROUP BY directory
            """, arguments: [sourceId])

        var totals: [String: (count: Int, size: Int64)] = [:]
        for row in rows {
            guard var directory: String = row["directory"], directory == root || directory.hasPrefix(root) else {
                continue
            }
            let count: Int = row["n"]
            let size: Int64 = row["total"]
            while true {
                totals[directory, default: (0, 0)].count += count
                totals[directory, default: (0, 0)].size += size
                if directory.count <= root.count { break }
                directory = (directory as NSString).deletingLastPathComponent
            }
        }

        let insert = try db.cachedStatement(
            sql: "INSERT INTO folder (sourceId, path, parent, name, count, size) VALUES (?, ?, ?, ?, ?, ?)")
        for (path, total) in totals {
            let parent = path == root ? nil : (path as NSString).deletingLastPathComponent
            try insert.execute(arguments: [sourceId, path, parent, (path as NSString).lastPathComponent,
                                           total.count, total.size])
        }
    }

    /// Records a scan that did not finish. Nothing is deleted.
    public func abortScan(scanId: Int64, status: ScanStatus, counters: ScanCounters) async throws {
        try await pool.write { db in
            try Self.updateScan(db, scanId: scanId, status: status, counters: counters)
        }
    }

    static func updateScan(_ db: Database, scanId: Int64, status: ScanStatus, counters: ScanCounters) throws {
        try db.execute(sql: """
            UPDATE scan SET finishedAt = ?, status = ?, filesWalked = ?, filesUnchanged = ?,
                            filesParsed = ?, filesDeleted = ?, errors = ?
            WHERE id = ?
            """, arguments: [Date(), status.rawValue, counters.walked, counters.unchanged,
                             counters.parsed, counters.deleted, counters.errors, scanId])
    }
}

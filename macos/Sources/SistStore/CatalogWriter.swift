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
/// 2. `write` upserts parse results, stamped with the current scan.
/// 3. `finishScan` stamps the members of unchanged archives (they were not parsed, so nothing
///    stamped them), then deletes every document of the source the scan did not see.
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
        let rootPrefix = source.root == "/" ? "/" : source.root + "/"

        try await pool.write { db in
            let findParent = try db.cachedStatement(sql: "SELECT id FROM document WHERE sourceId = ? AND path = ?")
            let upsert = try db.cachedStatement(sql: """
                INSERT INTO document (sourceId, parentId, path, name, ext, mime, category, size, mtime, title,
                                      metadata, checksum, error, thumbnailCount, scanId, seenScanId)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (sourceId, path) DO UPDATE SET
                    parentId = excluded.parentId, name = excluded.name, ext = excluded.ext, mime = excluded.mime,
                    category = excluded.category, size = excluded.size, mtime = excluded.mtime,
                    title = excluded.title, metadata = excluded.metadata, checksum = excluded.checksum,
                    error = excluded.error, thumbnailCount = excluded.thumbnailCount,
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
                if let parentPath = doc.parentPath {
                    parentId = try Int64.fetchOne(findParent, arguments: [source.id, parentPath])
                }
                let metadata = doc.metadata.isEmpty
                    ? nil : String(decoding: try encoder.encode(doc.metadata), as: UTF8.self)

                guard let id = try Int64.fetchOne(upsert, arguments: [
                    source.id, parentId, doc.path, doc.name, doc.ext, doc.mime, doc.category.rawValue,
                    doc.size, doc.mtime, doc.title, metadata, doc.checksum, doc.error,
                    result.thumbnails.count, scanId, scanId,
                ]) else { continue }

                if let content = doc.content, !content.isEmpty {
                    try upsertContent.execute(arguments: [id, content])
                } else {
                    try deleteContent.execute(arguments: [id])
                }

                // Directories above the document, relative to the source: `name` is its own column
                // and the root itself would match every document
                var directory = (doc.path as NSString).deletingLastPathComponent
                if directory.hasPrefix(rootPrefix) {
                    directory.removeFirst(rootPrefix.count)
                } else if directory + "/" == rootPrefix {
                    directory = ""
                }

                try deleteFTS.execute(arguments: [id])
                try insertFTS.execute(arguments: [
                    id,
                    SearchText.indexable(doc.name),
                    doc.title.map(SearchText.indexable),
                    doc.content.map(SearchText.indexable),
                    SearchText.indexable(directory),
                ])

                try deleteThumbnails.execute(arguments: [id])
                for (number, data) in result.thumbnails.enumerated() {
                    try insertThumbnail.execute(arguments: [id, number, data])
                }
            }
        }
    }

    /// Returns the number of documents deleted.
    @discardableResult
    public func finishScan(sourceId: Int64, scanId: Int64, counters: ScanCounters) async throws -> Int {
        try await pool.write { db in
            try db.execute(sql: """
                WITH RECURSIVE
                    unchanged(id) AS (
                        SELECT id FROM document WHERE sourceId = :source AND seenScanId = :scan AND scanId < :scan
                    ),
                    descendant(id) AS (
                        SELECT d.id FROM document d JOIN unchanged u ON d.parentId = u.id
                        UNION
                        SELECT d.id FROM document d JOIN descendant p ON d.parentId = p.id
                    )
                UPDATE document SET seenScanId = :scan WHERE id IN (SELECT id FROM descendant)
                """, arguments: ["source": sourceId, "scan": scanId])

            let deleted = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM document WHERE sourceId = ? AND seenScanId < ?",
                arguments: [sourceId, scanId]) ?? 0
            try db.execute(sql: "DELETE FROM document WHERE sourceId = ? AND seenScanId < ?",
                           arguments: [sourceId, scanId])

            var counters = counters
            counters.deleted = deleted
            try Self.updateScan(db, scanId: scanId, status: .completed, counters: counters)
            try db.execute(sql: "UPDATE source SET lastScanAt = ?, lastScanId = ? WHERE id = ?",
                           arguments: [Date(), scanId, sourceId])
            return deleted
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

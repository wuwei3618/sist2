import Foundation
import GRDB
import SistCore

/// The data behind the stats page (sist2's treemap, mime and size/date aggregations).
public struct CatalogStats: Sendable, Hashable {
    public struct Bucket: Sendable, Hashable, Identifiable {
        public var label: String
        public var count: Int
        public var size: Int64
        public var id: String { label }
    }

    public var documentCount: Int
    public var totalSize: Int64
    public var byCategory: [Bucket]
    public var topMimeTypes: [Bucket]
    public var sizeHistogram: [Bucket]
    public var byYear: [Bucket]
    /// Size of each first-level folder of the source (empty when stats span several sources)
    public var topFolders: [Bucket]
}

extension Catalog {
    /// Stats of one source, or of all of them. Archive members are left out of size totals: their
    /// size is already counted in their archive.
    public func stats(sourceId: Int64? = nil) async throws -> CatalogStats {
        try await pool.read { db in
            let scope = sourceId == nil ? "parentId IS NULL" : "parentId IS NULL AND sourceId = \(sourceId!)"

            func buckets(_ sql: String) throws -> [CatalogStats.Bucket] {
                try Row.fetchAll(db, sql: sql).map {
                    CatalogStats.Bucket(label: $0["label"] ?? "", count: $0["n"], size: $0["total"] ?? 0)
                }
            }

            let totals = try Row.fetchOne(db, sql: "SELECT count(*) AS n, coalesce(sum(size), 0) AS total FROM document WHERE \(scope)")

            let byCategory = try buckets("""
                SELECT category AS label, count(*) AS n, sum(size) AS total FROM document
                WHERE \(scope) GROUP BY category ORDER BY total DESC
                """)
            let topMimeTypes = try buckets("""
                SELECT coalesce(mime, '?') AS label, count(*) AS n, sum(size) AS total FROM document
                WHERE \(scope) GROUP BY mime ORDER BY n DESC LIMIT 20
                """)
            let sizeHistogram = try buckets("""
                SELECT CASE
                    WHEN size < 1024 THEN '< 1 KB'
                    WHEN size < 10240 THEN '1-10 KB'
                    WHEN size < 102400 THEN '10-100 KB'
                    WHEN size < 1048576 THEN '100 KB-1 MB'
                    WHEN size < 10485760 THEN '1-10 MB'
                    WHEN size < 104857600 THEN '10-100 MB'
                    WHEN size < 1073741824 THEN '100 MB-1 GB'
                    ELSE '> 1 GB' END AS label,
                    min(size) AS lowest, count(*) AS n, sum(size) AS total
                FROM document WHERE \(scope) GROUP BY label ORDER BY lowest
                """)
            let byYear = try buckets("""
                SELECT strftime('%Y', mtime, 'unixepoch') AS label, count(*) AS n, sum(size) AS total
                FROM document WHERE \(scope) GROUP BY label ORDER BY label
                """)

            var topFolders: [CatalogStats.Bucket] = []
            if let sourceId, let root = try String.fetchOne(db, sql: "SELECT root FROM source WHERE id = ?", arguments: [sourceId]) {
                let prefix = root == "/" ? "/" : root + "/"
                topFolders = try Row.fetchAll(db, sql: """
                    SELECT CASE WHEN instr(rest, '/') > 0 THEN substr(rest, 1, instr(rest, '/') - 1) ELSE '.' END AS label,
                           count(*) AS n, sum(size) AS total
                    FROM (SELECT substr(path, ?) AS rest, size FROM document WHERE \(scope))
                    GROUP BY label ORDER BY total DESC LIMIT 30
                    """, arguments: [prefix.unicodeScalars.count + 1]).map {
                        CatalogStats.Bucket(label: $0["label"], count: $0["n"], size: $0["total"] ?? 0)
                    }
            }

            return CatalogStats(documentCount: totals?["n"] ?? 0, totalSize: totals?["total"] ?? 0,
                                byCategory: byCategory, topMimeTypes: topMimeTypes, sizeHistogram: sizeHistogram,
                                byYear: byYear, topFolders: topFolders)
        }
    }
}

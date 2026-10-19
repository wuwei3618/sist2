import Foundation
import GRDB
import SistCore

public enum CatalogError: Error, CustomStringConvertible {
    case sourceNotFound(Int64)
    case sourceExists(String)

    public var description: String {
        switch self {
        case .sourceNotFound(let id): return "No source with id \(id)"
        case .sourceExists(let root): return "\(root) is already indexed"
        }
    }
}

/// The catalog database. WAL mode: the scan writes while the UI reads.
public final class Catalog: Sendable {
    public let pool: DatabasePool
    public let path: String

    public init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(10)
        configuration.prepareDatabase { db in
            // Thumbnails and content make the database large; keep the page cache bounded
            try db.execute(sql: "PRAGMA cache_size = -65536")
        }
        self.path = path
        self.pool = try DatabasePool(path: path, configuration: configuration)
        try Schema.migrator().migrate(pool)
    }

    /// `~/Library/Application Support/Sist/catalog.sqlite` on macOS, shared by the app and the CLI
    public static var defaultPath: String {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sist/catalog.sqlite").path
        #else
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/share")
        return (base as NSString).appendingPathComponent("sist/catalog.sqlite")
        #endif
    }

    public var writer: CatalogWriter { CatalogWriter(pool: pool) }

    // MARK: Sources

    public func addSource(root: String, name: String? = nil, options: ScanOptions = ScanOptions()) async throws -> Source {
        let root = Self.normalizedRoot(root)
        let name = name ?? (root as NSString).lastPathComponent
        let optionsJSON = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        return try await pool.write { db in
            if try Bool.fetchOne(db, sql: "SELECT 1 FROM source WHERE root = ?", arguments: [root]) == true {
                throw CatalogError.sourceExists(root)
            }
            try db.execute(
                sql: "INSERT INTO source (name, root, options, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [name, root, optionsJSON, Date()])
            return try Source.fetchOne(db, sql: "SELECT * FROM source WHERE id = ?", arguments: [db.lastInsertedRowID])!
        }
    }

    public func updateSource(id: Int64, name: String? = nil, options: ScanOptions? = nil) async throws {
        try await pool.write { db in
            if let name {
                try db.execute(sql: "UPDATE source SET name = ? WHERE id = ?", arguments: [name, id])
            }
            if let options {
                let json = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
                try db.execute(sql: "UPDATE source SET options = ? WHERE id = ?", arguments: [json, id])
            }
        }
    }

    /// Deletes the source and everything indexed from it.
    public func removeSource(id: Int64) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [id])
        }
    }

    public func source(id: Int64) async throws -> Source {
        guard let source = try await pool.read({ db in
            try Source.fetchOne(db, sql: "SELECT * FROM source WHERE id = ?", arguments: [id])
        }) else {
            throw CatalogError.sourceNotFound(id)
        }
        return source
    }

    public func source(root: String) async throws -> Source? {
        let root = Self.normalizedRoot(root)
        return try await pool.read { db in
            try Source.fetchOne(db, sql: "SELECT * FROM source WHERE root = ?", arguments: [root])
        }
    }

    public func sources() async throws -> [SourceInfo] {
        try await pool.read(Self.fetchSourceInfos)
    }

    /// Emits the sources again whenever a scan writes, so counts update live.
    public func sourceUpdates() -> AsyncThrowingStream<[SourceInfo], Error> {
        let observation = ValueObservation.tracking(Self.fetchSourceInfos).removeDuplicates()
        let pool = self.pool
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await infos in observation.values(in: pool) {
                        continuation.yield(infos)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @Sendable static func fetchSourceInfos(_ db: Database) throws -> [SourceInfo] {
        let sources = try Source.fetchAll(db, sql: "SELECT * FROM source ORDER BY name COLLATE NOCASE")
        var infos: [SourceInfo] = []
        for source in sources {
            let row = try Row.fetchOne(db, sql: """
                SELECT count(*) AS n, coalesce(sum(size), 0) AS total
                FROM document WHERE sourceId = ? AND parentId IS NULL
                """, arguments: [source.id])
            let lastScan = try ScanRecord.fetchOne(
                db, sql: "SELECT * FROM scan WHERE sourceId = ? ORDER BY id DESC LIMIT 1", arguments: [source.id])
            infos.append(SourceInfo(source: source, documentCount: row?["n"] ?? 0,
                                    totalSize: row?["total"] ?? 0, lastScan: lastScan))
        }
        return infos
    }

    static func normalizedRoot(_ root: String) -> String {
        var root = (root as NSString).standardizingPath
        while root.count > 1 && root.hasSuffix("/") {
            root.removeLast()
        }
        return root
    }

    // MARK: Documents

    public func document(id: Int64) async throws -> DocumentDetail? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT \(DocumentSummary.columns), d.metadata, d.checksum, d.error, d.scanId FROM document d WHERE d.id = ?",
                arguments: [id]) else { return nil }
            let summary = try DocumentSummary(row: row)
            let metadataJSON: String? = row["metadata"]
            let metadata = metadataJSON.flatMap {
                try? JSONDecoder().decode([String: MetadataValue].self, from: Data($0.utf8))
            } ?? [:]
            let content = try String.fetchOne(db, sql: "SELECT text FROM content WHERE documentId = ?", arguments: [id])
            let tags = try String.fetchAll(db, sql: "SELECT name FROM tag WHERE documentId = ? ORDER BY name", arguments: [id])
            return DocumentDetail(summary: summary, content: content, metadata: metadata,
                                  checksum: row["checksum"], error: row["error"], tags: tags, scanId: row["scanId"])
        }
    }

    public func thumbnail(documentId: Int64, number: Int = 0) async throws -> Data? {
        try await pool.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM thumbnail WHERE documentId = ? AND num = ?",
                              arguments: [documentId, number])
        }
    }

    /// Members of an archive, for browsing into it
    public func children(of documentId: Int64, limit: Int = 500) async throws -> [DocumentSummary] {
        try await pool.read { db in
            try DocumentSummary.fetchAll(
                db, sql: "SELECT \(DocumentSummary.columns) FROM document d WHERE d.parentId = ? ORDER BY d.path LIMIT ?",
                arguments: [documentId, limit])
        }
    }

    // MARK: Tags

    public func addTag(_ name: String, to documentId: Int64) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try await pool.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO tag (documentId, name) VALUES (?, ?)", arguments: [documentId, name])
        }
    }

    public func removeTag(_ name: String, from documentId: Int64) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM tag WHERE documentId = ? AND name = ?", arguments: [documentId, name])
        }
    }

    public func tags() async throws -> [TagCount] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT name, count(*) AS n FROM tag GROUP BY name ORDER BY name").map {
                TagCount(name: $0["name"], count: $0["n"])
            }
        }
    }
}

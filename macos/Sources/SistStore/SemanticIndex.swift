import Foundation
import GRDB
import GRDBSQLite
import SistCore

public enum EmbeddingKind: String, Sendable, CaseIterable {
    /// Passages of a document's text
    case text
    /// An image's thumbnail
    case image
}

/// A document waiting for the semantic indexer.
public struct PendingDocument: Sendable {
    public var id: Int64
    public var scanId: Int64
    public var kind: EmbeddingKind
    /// For text
    public var content: String?
    /// For images: the stored thumbnail
    public var thumbnail: Data?
}

/// What the semantic indexer learnt about a document.
public struct SemanticUpdate: Sendable {
    public var documentId: Int64
    /// The parse it was computed for: dropped if the document has been parsed again since
    public var scanId: Int64
    public var kind: EmbeddingKind
    /// By passage (or 0 for an image)
    public var embeddings: [(chunk: Int, embedding: Embedding)]
    /// Image labels: added to the document's full-text row and metadata
    public var labels: [String]

    public init(documentId: Int64, scanId: Int64, kind: EmbeddingKind,
                embeddings: [(chunk: Int, embedding: Embedding)], labels: [String] = []) {
        self.documentId = documentId
        self.scanId = scanId
        self.kind = kind
        self.embeddings = embeddings
        self.labels = labels
    }
}

public struct SemanticStatus: Sendable, Hashable {
    public var indexed: [EmbeddingKind: Int] = [:]
    public var pending: [EmbeddingKind: Int] = [:]
    public var vectors = 0
}

extension Catalog {
    // MARK: Settings

    public static let semanticSearchSetting = "semanticSearch"

    public func setting(_ key: String) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key])
        }
    }

    public func setSetting(_ key: String, _ value: String?) async throws {
        try await pool.write { db in
            if let value {
                try db.execute(sql: "INSERT OR REPLACE INTO setting (key, value) VALUES (?, ?)", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key])
            }
        }
    }

    /// Semantic indexing costs time: it is off until asked for
    public func isSemanticSearchEnabled() async -> Bool {
        (try? await setting(Self.semanticSearchSetting)) == "1"
    }

    // MARK: Indexing

    private static let pendingCondition = """
        NOT EXISTS (SELECT 1 FROM embedding_status s WHERE s.documentId = d.id AND s.kind = ? AND s.scanId = d.scanId)
        """

    private static func kindCondition(_ kind: EmbeddingKind) -> String {
        switch kind {
        case .text: return "EXISTS (SELECT 1 FROM content c WHERE c.documentId = d.id)"
        case .image: return "d.category = 'image' AND d.thumbnailCount > 0"
        }
    }

    /// Documents not analysed since they were last parsed, oldest first
    public func pendingDocuments(kind: EmbeddingKind, limit: Int) async throws -> [PendingDocument] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.id, d.scanId FROM document d
                WHERE \(Self.kindCondition(kind)) AND \(Self.pendingCondition)
                ORDER BY d.id LIMIT ?
                """, arguments: [kind.rawValue, limit])
            return try rows.map { row in
                let id: Int64 = row["id"]
                var document = PendingDocument(id: id, scanId: row["scanId"], kind: kind)
                switch kind {
                case .text:
                    document.content = try DatabaseValue.fetchOne(
                        db, sql: "SELECT text FROM content WHERE documentId = ?", arguments: [id]).flatMap(ContentCodec.decode)
                case .image:
                    document.thumbnail = try Data.fetchOne(
                        db, sql: "SELECT data FROM thumbnail WHERE documentId = ? ORDER BY num LIMIT 1", arguments: [id])
                }
                return document
            }
        }
    }

    public func semanticStatus() async throws -> SemanticStatus {
        try await pool.read { db in
            var status = SemanticStatus()
            for kind in EmbeddingKind.allCases {
                let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM document d WHERE \(Self.kindCondition(kind))") ?? 0
                let pending = try Int.fetchOne(db, sql: """
                    SELECT count(*) FROM document d WHERE \(Self.kindCondition(kind)) AND \(Self.pendingCondition)
                    """, arguments: [kind.rawValue]) ?? 0
                status.pending[kind] = pending
                status.indexed[kind] = total - pending
            }
            status.vectors = try Int.fetchOne(db, sql: "SELECT count(*) FROM embedding") ?? 0
            return status
        }
    }

    /// Stores what the indexer computed, in one transaction. Updates for documents parsed again
    /// meanwhile are dropped: they will be analysed again.
    public func store(_ updates: [SemanticUpdate]) async throws {
        guard !updates.isEmpty else { return }
        try await pool.write { db in
            let current = try db.cachedStatement(sql: """
                SELECT d.scanId, d.path, d.name, d.title, d.metadata, s.root FROM document d
                JOIN source s ON s.id = d.sourceId WHERE d.id = ?
                """)
            let deleteVectors = try db.cachedStatement(sql: "DELETE FROM embedding WHERE documentId = ? AND kind = ?")
            let insertVector = try db.cachedStatement(sql: """
                INSERT OR REPLACE INTO embedding (model, documentId, kind, chunk, vector) VALUES (?, ?, ?, ?, ?)
                """)
            let markDone = try db.cachedStatement(sql: """
                INSERT OR REPLACE INTO embedding_status (documentId, kind, scanId) VALUES (?, ?, ?)
                """)
            for update in updates {
                guard let row = try Row.fetchOne(current, arguments: [update.documentId]),
                      (row["scanId"] as Int64) == update.scanId else { continue }
                try deleteVectors.execute(arguments: [update.documentId, update.kind.rawValue])
                for (chunk, embedding) in update.embeddings {
                    try insertVector.execute(arguments: [embedding.model, update.documentId, update.kind.rawValue, chunk,
                                                         VectorCodec.encode(embedding.vector)])
                }
                if !update.labels.isEmpty {
                    try addLabels(update.labels, to: update.documentId, row: row, db: db)
                }
                try markDone.execute(arguments: [update.documentId, update.kind.rawValue, update.scanId])
            }
        }
    }

    /// Image labels go into the metadata (shown in the inspector) and into the full-text row, so
    /// that "beach" finds photos of beaches
    private func addLabels(_ labels: [String], to id: Int64, row: Row, db: Database) throws {
        var metadata = (row["metadata"] as String?).flatMap {
            try? JSONDecoder().decode([String: MetadataValue].self, from: Data($0.utf8))
        } ?? [:]
        metadata[MetaKey.imageLabels] = .string(labels.joined(separator: ", "))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try db.execute(sql: "UPDATE document SET metadata = ? WHERE id = ?",
                       arguments: [String(decoding: try encoder.encode(metadata), as: UTF8.self), id])

        let content = try DatabaseValue.fetchOne(db, sql: "SELECT text FROM content WHERE documentId = ?", arguments: [id])
            .flatMap(ContentCodec.decode)
        let document = ParsedDocument(path: row["path"], name: row["name"], ext: "", mime: nil, size: 0, mtime: 0,
                                      title: row["title"], content: [content, labels.joined(separator: " ")]
                                          .compactMap { $0 }.joined(separator: "\n"))
        let text = SearchText.indexedText(for: document, root: row["root"])
        try db.execute(sql: "DELETE FROM document_fts WHERE rowid = ?", arguments: [id])
        try db.execute(sql: "INSERT INTO document_fts (rowid, name, title, content, path) VALUES (?, ?, ?, ?, ?)",
                       arguments: [id, text.name, text.title, text.content, text.path])
    }

    /// A document's own vector (its first passage, or its image), to find documents like it
    public func embedding(documentId: Int64, kind: EmbeddingKind) async throws -> Embedding? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT model, vector FROM embedding WHERE documentId = ? AND kind = ? ORDER BY chunk LIMIT 1
                """, arguments: [documentId, kind.rawValue]),
                let vector = VectorCodec.decode(row["vector"]) else { return nil }
            return Embedding(model: row["model"], vector: vector)
        }
    }

    // MARK: Search

    /// The documents closest to `query`, best first, each with the passage that matched best: a
    /// linear scan of the model's vectors (as sist2's SQLite backend does). The rows come grouped
    /// by document and are read in place, straight from SQLite (GRDB's rows double the time of a
    /// scan this size); the best `limit` documents are kept in a heap.
    static func nearest(_ query: Embedding, limit: Int, excluding excluded: Int64?,
                        db: Database) throws -> [(id: Int64, score: Float, chunk: Int)] {
        let unit = VectorCodec.normalized(query.vector)
        var top = TopK(limit: limit)
        var current: (id: Int64, score: Float, chunk: Int)?
        let statement = try db.makeStatement(sql: "SELECT documentId, chunk, vector FROM embedding WHERE model = ? ORDER BY documentId")
        try statement.setArguments([query.model])
        let handle = statement.sqliteStatement
        defer { sqlite3_reset(handle) }
        try unit.withUnsafeBufferPointer { unitQuery in
            while true {
                let code = sqlite3_step(handle)
                guard code == SQLITE_ROW else {
                    guard code == SQLITE_DONE else {
                        throw DatabaseError(resultCode: ResultCode(rawValue: code),
                                            message: String(cString: sqlite3_errmsg(db.sqliteConnection)),
                                            sql: statement.sql)
                    }
                    break
                }
                let id = sqlite3_column_int64(handle, 0)
                guard id != excluded, let blob = sqlite3_column_blob(handle, 2) else { continue }
                let stored = UnsafeRawBufferPointer(start: blob, count: Int(sqlite3_column_bytes(handle, 2)))
                guard let score = VectorCodec.similarity(stored, unitQuery: unitQuery) else { continue }
                if let best = current, best.id != id {
                    top.insert(best)
                    current = nil
                }
                if current.map({ score > $0.score }) ?? true {
                    current = (id, score, Int(sqlite3_column_int(handle, 1)))
                }
            }
        }
        if let best = current {
            top.insert(best)
        }
        return top.sorted()
    }
}

/// The best `limit` of a stream of scored documents: a min-heap on the score.
struct TopK {
    let limit: Int
    private var heap: [(id: Int64, score: Float, chunk: Int)] = []

    init(limit: Int) {
        self.limit = limit
        heap.reserveCapacity(limit)
    }

    /// Lower score first; for equal scores the larger id, so that smaller ids win ties
    private static func below(_ a: (id: Int64, score: Float, chunk: Int), _ b: (id: Int64, score: Float, chunk: Int)) -> Bool {
        a.score < b.score || (a.score == b.score && a.id > b.id)
    }

    mutating func insert(_ item: (id: Int64, score: Float, chunk: Int)) {
        guard limit > 0 else { return }
        if heap.count < limit {
            heap.append(item)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard Self.below(heap[child], heap[parent]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        } else if Self.below(heap[0], item) {
            heap[0] = item
            var parent = 0
            while true {
                let left = 2 * parent + 1
                let right = left + 1
                var smallest = parent
                if left < heap.count, Self.below(heap[left], heap[smallest]) { smallest = left }
                if right < heap.count, Self.below(heap[right], heap[smallest]) { smallest = right }
                guard smallest != parent else { break }
                heap.swapAt(parent, smallest)
                parent = smallest
            }
        }
    }

    /// Best first
    func sorted() -> [(id: Int64, score: Float, chunk: Int)] {
        heap.sorted { Self.below($1, $0) }
    }
}

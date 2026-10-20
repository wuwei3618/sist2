import Foundation
import GRDB
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
                INSERT OR REPLACE INTO embedding (documentId, kind, chunk, model, vector) VALUES (?, ?, ?, ?, ?)
                """)
            let markDone = try db.cachedStatement(sql: """
                INSERT OR REPLACE INTO embedding_status (documentId, kind, scanId) VALUES (?, ?, ?)
                """)
            for update in updates {
                guard let row = try Row.fetchOne(current, arguments: [update.documentId]),
                      (row["scanId"] as Int64) == update.scanId else { continue }
                try deleteVectors.execute(arguments: [update.documentId, update.kind.rawValue])
                for (chunk, embedding) in update.embeddings {
                    try insertVector.execute(arguments: [update.documentId, update.kind.rawValue, chunk, embedding.model,
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
    /// linear scan of the model's vectors (as sist2's SQLite backend does), fast enough for
    /// hundreds of thousands of vectors.
    static func nearest(_ query: Embedding, limit: Int, excluding excluded: Int64?,
                        db: Database) throws -> [(id: Int64, score: Float, chunk: Int)] {
        let unit = VectorCodec.normalized(query.vector)
        var best: [Int64: (score: Float, chunk: Int)] = [:]
        let rows = try Row.fetchCursor(db, sql: "SELECT documentId, chunk, vector FROM embedding WHERE model = ?",
                                       arguments: [query.model])
        while let row = try rows.next() {
            let id: Int64 = row[0]
            guard id != excluded, let score = VectorCodec.similarity(row[2], unitQuery: unit) else { continue }
            if best[id].map({ score > $0.score }) ?? true {
                best[id] = (score, row[1])
            }
        }
        return best.sorted { $0.value.score > $1.value.score || ($0.value.score == $1.value.score && $0.key < $1.key) }
            .prefix(limit).map { ($0.key, $0.value.score, $0.value.chunk) }
    }
}

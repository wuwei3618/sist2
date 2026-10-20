import Foundation
import GRDB
import SistCore

public enum SearchSort: String, CaseIterable, Sendable, Codable {
    case relevance
    case modifiedNewest
    case modifiedOldest
    case sizeLargest
    case sizeSmallest
    case name
}

public struct SearchQuery: Sendable, Hashable {
    public var text = ""
    public var sourceIds: Set<Int64> = []
    public var categories: Set<MimeCategory> = []
    public var mimeTypes: Set<String> = []
    /// Absolute directory; documents below it match
    public var pathPrefix: String?
    public var minSize: Int64?
    public var maxSize: Int64?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    /// Documents carrying all of these tags
    public var tags: Set<String> = []
    public var includeArchiveMembers = true
    public var sort: SearchSort = .relevance
    public var limit = 100
    public var offset = 0
    /// Count matches per category (for the sidebar), ignoring the category filter, and in total.
    /// Further pages of the same search can skip it: `total` is then only a lower bound.
    public var countCategories = true
    /// Semantic search: the query as a vector of the model the documents were embedded with
    /// (the text, embedded by the caller, or an image's feature print). Full-text matches of
    /// `text` are mixed in unless `semanticOnly`.
    public var semantic: Embedding?
    public var semanticOnly = false
    /// Left out of the results: the image whose look-alikes are searched for
    public var excludedDocument: Int64?

    public init(text: String = "") {
        self.text = text
    }
}

public struct SearchHit: Sendable, Hashable, Identifiable {
    public var document: DocumentSummary
    public var excerpt: Snippet?
    /// Cosine similarity, for semantic matches
    public var similarity: Float?
    public var id: Int64 { document.id }
}

public struct SearchResults: Sendable {
    public var hits: [SearchHit]
    public var total: Int
    public var categoryCounts: [MimeCategory: Int]
    /// What the UI should mark in names and previews
    public var highlightTerms: [String]
    public var elapsed: TimeInterval

    public static let empty = SearchResults(hits: [], total: 0, categoryCounts: [:], highlightTerms: [], elapsed: 0)
}

/// The conditions of a query's filters on `document d`, the category one kept apart so that
/// facet counts can leave it out.
struct SearchFilters {
    var conditions: [String] = []
    var arguments = StatementArguments()
    var categoryCondition: String?
    var categoryArguments = StatementArguments()

    func whereClause(including extra: [String], categories: Bool) -> String {
        let all = extra + conditions + (categories ? categoryCondition.map { [$0] } ?? [] : [])
        return all.isEmpty ? "" : "WHERE " + all.joined(separator: " AND ")
    }

    init(_ query: SearchQuery) {
        if !query.sourceIds.isEmpty {
            conditions.append("d.sourceId IN (\(Catalog.placeholders(query.sourceIds.count)))")
            _ = arguments.append(contentsOf: StatementArguments(Array(query.sourceIds)))
        }
        if !query.mimeTypes.isEmpty {
            conditions.append("d.mime IN (\(Catalog.placeholders(query.mimeTypes.count)))")
            _ = arguments.append(contentsOf: StatementArguments(Array(query.mimeTypes)))
        }
        if let prefix = query.pathPrefix {
            let directory = prefix.hasSuffix("/") ? prefix : prefix + "/"
            // '0' sorts right after '/': a range on the unique (sourceId, path) index
            conditions.append("(d.path >= ? AND d.path < ?)")
            _ = arguments.append(contentsOf: [directory, String(directory.dropLast()) + "0"])
        }
        if let minSize = query.minSize {
            conditions.append("d.size >= ?")
            _ = arguments.append(contentsOf: [minSize])
        }
        if let maxSize = query.maxSize {
            conditions.append("d.size <= ?")
            _ = arguments.append(contentsOf: [maxSize])
        }
        if let after = query.modifiedAfter {
            conditions.append("d.mtime >= ?")
            _ = arguments.append(contentsOf: [Int64(after.timeIntervalSince1970)])
        }
        if let before = query.modifiedBefore {
            conditions.append("d.mtime < ?")
            _ = arguments.append(contentsOf: [Int64(before.timeIntervalSince1970)])
        }
        if !query.tags.isEmpty {
            conditions.append("""
                d.id IN (SELECT documentId FROM tag WHERE name IN (\(Catalog.placeholders(query.tags.count)))
                         GROUP BY documentId HAVING count(*) = \(query.tags.count))
                """)
            _ = arguments.append(contentsOf: StatementArguments(Array(query.tags)))
        }
        if !query.includeArchiveMembers {
            conditions.append("d.parentId IS NULL")
        }
        if !query.categories.isEmpty {
            categoryCondition = "d.category IN (\(Catalog.placeholders(query.categories.count)))"
            categoryArguments = StatementArguments(query.categories.map(\.rawValue))
        }
    }
}

extension Catalog {
    public func search(_ query: SearchQuery) async throws -> SearchResults {
        if query.semantic != nil {
            return try await semanticSearch(query)
        }
        let started = Date()
        let parsed = QueryParser.parse(query.text)

        return try await pool.read { db in
            var from = "document d"
            let filters = SearchFilters(query)
            var conditions = filters.conditions
            var arguments = StatementArguments()

            if let fts = parsed.ftsExpression {
                from = "document_fts JOIN document d ON d.id = document_fts.rowid"
                conditions.insert("document_fts MATCH ?", at: 0)
                _ = arguments.append(contentsOf: [fts])
            }
            _ = arguments.append(contentsOf: filters.arguments)
            let categoryCondition = filters.categoryCondition
            let categoryArguments = filters.categoryArguments

            func whereClause(_ extra: String?) -> String {
                let all = conditions + (extra.map { [$0] } ?? [])
                return all.isEmpty ? "" : "WHERE " + all.joined(separator: " AND ")
            }
            let filtered = whereClause(categoryCondition)
            let filteredArguments = arguments + categoryArguments

            let order: String
            switch query.sort {
            case .relevance: order = parsed.ftsExpression != nil ? "document_fts.rank" : "d.mtime DESC"
            case .modifiedNewest: order = "d.mtime DESC"
            case .modifiedOldest: order = "d.mtime ASC"
            case .sizeLargest: order = "d.size DESC"
            case .sizeSmallest: order = "d.size ASC"
            case .name: order = "d.name COLLATE NOCASE ASC"
            }

            let documents = try DocumentSummary.fetchAll(db, sql: """
                SELECT \(DocumentSummary.columns) FROM \(from) \(filtered)
                ORDER BY \(order), d.id LIMIT ? OFFSET ?
                """, arguments: filteredArguments + [query.limit, query.offset])

            // One pass over the matches gives the facets and, summed over the categories the filter
            // keeps, the total: a broad full-text query is not walked twice more
            var categoryCounts: [MimeCategory: Int] = [:]
            var total = query.offset + documents.count
            if query.countCategories {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.category AS category, count(*) AS n FROM \(from) \(whereClause(nil)) GROUP BY d.category
                    """, arguments: arguments)
                for row in rows {
                    if let category = MimeCategory(rawValue: row["category"]) {
                        categoryCounts[category] = row["n"]
                    }
                }
                total = categoryCounts
                    .filter { query.categories.isEmpty || query.categories.contains($0.key) }
                    .values.reduce(0, +)
            }

            let hits = try Self.hits(documents, terms: parsed.highlightTerms, db: db)

            return SearchResults(hits: hits, total: total, categoryCounts: categoryCounts,
                                 highlightTerms: parsed.highlightTerms, elapsed: Date().timeIntervalSince(started))
        }
    }

    /// Hits for documents: excerpts are cut from the stored text, around the terms that were typed
    /// (without terms there is nothing to show one for), or, for a semantic match, from the
    /// passage that matched. Decompressing and matching take longer than the query itself, so
    /// they run in parallel.
    static func hits(_ documents: [DocumentSummary], terms: [String], passages: [Int64: (chunk: Int, score: Float)] = [:],
                     db: Database) throws -> [SearchHit] {
        var stored: [Int64: DatabaseValue] = [:]
        let wanted = documents.map(\.id).filter { !terms.isEmpty || passages[$0] != nil }
        if !wanted.isEmpty {
            let rows = try Row.fetchAll(
                db, sql: "SELECT documentId, text FROM content WHERE documentId IN (\(placeholders(wanted.count)))",
                arguments: StatementArguments(wanted))
            for row in rows {
                stored[row["documentId"]] = row["text"]
            }
        }
        let texts = documents.map { stored[$0.id] }
        let chunks = documents.map { passages[$0.id]?.chunk }
        var excerpts = [Snippet?](repeating: nil, count: texts.count)
        excerpts.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let output = buffer
            DispatchQueue.concurrentPerform(iterations: texts.count) { index in
                guard let value = texts[index], var text = ContentCodec.decode(value) else { return }
                if let chunk = chunks[index] {
                    let passages = Chunker.chunks(text)
                    if passages.indices.contains(chunk) {
                        let passage = passages[chunk]
                        output[index] = Highlighter.excerpt(passage, terms: terms)
                        return
                    }
                }
                if text.utf8.count > 100_000 {
                    text = String(text.prefix(100_000))
                }
                output[index] = Highlighter.excerpt(text, terms: terms)
            }
        }
        return zip(documents, excerpts).map {
            SearchHit(document: $0, excerpt: $1, similarity: passages[$0.id]?.score)
        }
    }

    /// Semantic search, as a fusion of two rankings: documents by the similarity of their best
    /// passage to the query vector, and (with text, unless `semanticOnly`) full-text matches by
    /// relevance. Reciprocal rank fusion needs no common scale between bm25 and cosine scores.
    /// Both lists are cut to their best 500, so totals are capped too.
    func semanticSearch(_ query: SearchQuery) async throws -> SearchResults {
        guard let vector = query.semantic else { return .empty }
        let started = Date()
        let parsed = QueryParser.parse(query.text)
        let candidates = 500

        return try await pool.read { db in
            let filters = SearchFilters(query)

            // Those of `ids` the filters let through (all but the category one), with their category
            func allowed(_ ids: [Int64]) throws -> [Int64: MimeCategory] {
                guard !ids.isEmpty else { return [:] }
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.id, d.category FROM document d
                    \(filters.whereClause(including: ["d.id IN (\(Self.placeholders(ids.count)))"], categories: false))
                    """, arguments: StatementArguments(ids) + filters.arguments)
                return Dictionary(rows.map { ($0["id"], MimeCategory(rawValue: $0["category"]) ?? .other) },
                                  uniquingKeysWith: { first, _ in first })
            }

            let nearest = try Self.nearest(vector, limit: candidates, excluding: query.excludedDocument, db: db)
            var passages: [Int64: (chunk: Int, score: Float)] = [:]
            for match in nearest {
                passages[match.id] = (match.chunk, match.score)
            }
            var categories = try allowed(nearest.map(\.id))
            var rankings = [nearest.map(\.id).filter { categories[$0] != nil }]

            if !query.semanticOnly, let fts = parsed.ftsExpression {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.id, d.category FROM document_fts JOIN document d ON d.id = document_fts.rowid
                    \(filters.whereClause(including: ["document_fts MATCH ?"], categories: false))
                    ORDER BY document_fts.rank LIMIT ?
                    """, arguments: [fts] + filters.arguments + [candidates])
                var ranking: [Int64] = []
                for row in rows where (row["id"] as Int64) != query.excludedDocument {
                    let id: Int64 = row["id"]
                    ranking.append(id)
                    categories[id] = MimeCategory(rawValue: row["category"]) ?? .other
                }
                rankings.append(ranking)
            }

            var fused: [Int64: Double] = [:]
            for ranking in rankings {
                for (rank, id) in ranking.enumerated() {
                    fused[id, default: 0] += 1 / Double(61 + rank)
                }
            }
            var ordered = fused.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map(\.key)

            var categoryCounts: [MimeCategory: Int] = [:]
            for id in ordered {
                categoryCounts[categories[id] ?? .other, default: 0] += 1
            }
            if !query.categories.isEmpty {
                ordered = ordered.filter { query.categories.contains(categories[$0] ?? .other) }
            }

            if query.sort != .relevance, !ordered.isEmpty {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, mtime, size, name FROM document WHERE id IN (\(Self.placeholders(ordered.count)))
                    """, arguments: StatementArguments(ordered))
                let fields = Dictionary(rows.map { ($0["id"] as Int64, (mtime: $0["mtime"] as Int64, size: $0["size"] as Int64,
                                                                        name: $0["name"] as String)) },
                                        uniquingKeysWith: { first, _ in first })
                ordered.sort { a, b in
                    guard let x = fields[a], let y = fields[b] else { return a < b }
                    switch query.sort {
                    case .relevance: return false
                    case .modifiedNewest: return x.mtime > y.mtime
                    case .modifiedOldest: return x.mtime < y.mtime
                    case .sizeLargest: return x.size > y.size
                    case .sizeSmallest: return x.size < y.size
                    case .name: return x.name.localizedCaseInsensitiveCompare(y.name) == .orderedAscending
                    }
                }
            }

            let page = Array(ordered.dropFirst(query.offset).prefix(query.limit))
            var documents: [DocumentSummary] = []
            if !page.isEmpty {
                let fetched = try DocumentSummary.fetchAll(db, sql: """
                    SELECT \(DocumentSummary.columns) FROM document d WHERE d.id IN (\(Self.placeholders(page.count)))
                    """, arguments: StatementArguments(page))
                let byId = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                documents = page.compactMap { byId[$0] }
            }
            let hits = try Self.hits(documents, terms: parsed.highlightTerms, passages: passages, db: db)
            return SearchResults(hits: hits, total: ordered.count, categoryCounts: categoryCounts,
                                 highlightTerms: parsed.highlightTerms, elapsed: Date().timeIntervalSince(started))
        }
    }

    /// Folders to offer while typing: those whose path starts with the text when it looks like a
    /// path (`~` for the home folder), else those whose name contains it; the fullest first.
    public func folders(matching text: String, limit: Int = 8) async throws -> [FolderInfo] {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        return try await pool.read { db in
            let rows: [Row]
            if text.hasPrefix("/") || text.hasPrefix("~") {
                let path = (text as NSString).expandingTildeInPath
                rows = try Row.fetchAll(db, sql: """
                    SELECT f.sourceId, f.path, f.name, f.count, f.size,
                           EXISTS (SELECT 1 FROM folder c WHERE c.sourceId = f.sourceId AND c.parent = f.path) AS sub
                    FROM folder f WHERE f.path >= ? AND f.path < ? ORDER BY length(f.path), f.path LIMIT ?
                    """, arguments: [path, path + "\u{10FFFF}", limit])
            } else {
                let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                rows = try Row.fetchAll(db, sql: """
                    SELECT f.sourceId, f.path, f.name, f.count, f.size,
                           EXISTS (SELECT 1 FROM folder c WHERE c.sourceId = f.sourceId AND c.parent = f.path) AS sub
                    FROM folder f WHERE f.name LIKE ? ESCAPE '\\' AND f.parent IS NOT NULL
                    ORDER BY f.count DESC LIMIT ?
                    """, arguments: ["%" + escaped + "%", limit])
            }
            return rows.map { Catalog.folderInfo($0, sourceId: $0["sourceId"]) }
        }
    }

    /// A corrected query when `text` finds nothing because of a typo: each Latin word missing from
    /// the index is replaced by the most common indexed word within one or two edits of it. Only
    /// suggested when the corrected query finds something.
    public func spellingSuggestion(for text: String) async throws -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let corrected: [String] = try await pool.read { db in
            try words.map { word in
                guard let candidate = try Spelling.correction(for: word, in: db) else { return word }
                return candidate
            }
        }
        guard corrected != words else { return nil }
        let suggestion = corrected.joined(separator: " ")
        var query = SearchQuery(text: suggestion)
        query.limit = 1
        query.countCategories = false
        return try await search(query).hits.isEmpty ? nil : suggestion
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}

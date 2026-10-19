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
    /// Count matches per category (for the sidebar), ignoring the category filter
    public var countCategories = true

    public init(text: String = "") {
        self.text = text
    }
}

public struct SearchHit: Sendable, Hashable, Identifiable {
    public var document: DocumentSummary
    public var excerpt: Snippet?
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

extension Catalog {
    public func search(_ query: SearchQuery) async throws -> SearchResults {
        let started = Date()
        let parsed = QueryParser.parse(query.text)

        return try await pool.read { db in
            var from = "document d"
            var conditions: [String] = []
            var arguments = StatementArguments()

            if let fts = parsed.ftsExpression {
                from = "document_fts JOIN document d ON d.id = document_fts.rowid"
                conditions.append("document_fts MATCH ?")
                _ = arguments.append(contentsOf: [fts])
            }
            if !query.sourceIds.isEmpty {
                conditions.append("d.sourceId IN (\(Self.placeholders(query.sourceIds.count)))")
                _ = arguments.append(contentsOf: StatementArguments(Array(query.sourceIds)))
            }
            if !query.mimeTypes.isEmpty {
                conditions.append("d.mime IN (\(Self.placeholders(query.mimeTypes.count)))")
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
                    d.id IN (SELECT documentId FROM tag WHERE name IN (\(Self.placeholders(query.tags.count)))
                             GROUP BY documentId HAVING count(*) = \(query.tags.count))
                    """)
                _ = arguments.append(contentsOf: StatementArguments(Array(query.tags)))
            }
            if !query.includeArchiveMembers {
                conditions.append("d.parentId IS NULL")
            }

            // The category filter is kept apart so the facet counts can leave it out
            var categoryCondition: String? = nil
            var categoryArguments = StatementArguments()
            if !query.categories.isEmpty {
                categoryCondition = "d.category IN (\(Self.placeholders(query.categories.count)))"
                categoryArguments = StatementArguments(query.categories.map(\.rawValue))
            }

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

            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(from) \(filtered)",
                                         arguments: filteredArguments) ?? 0

            var categoryCounts: [MimeCategory: Int] = [:]
            if query.countCategories {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.category AS category, count(*) AS n FROM \(from) \(whereClause(nil)) GROUP BY d.category
                    """, arguments: arguments)
                for row in rows {
                    if let category = MimeCategory(rawValue: row["category"]) {
                        categoryCounts[category] = row["n"]
                    }
                }
            }

            // Excerpts are cut from the stored text, around the terms that were typed
            var contents: [Int64: String] = [:]
            if !documents.isEmpty {
                let ids = documents.map(\.id)
                let rows = try Row.fetchAll(
                    db, sql: "SELECT documentId, substr(text, 1, 100000) AS text FROM content WHERE documentId IN (\(Self.placeholders(ids.count)))",
                    arguments: StatementArguments(ids))
                for row in rows {
                    contents[row["documentId"]] = row["text"]
                }
            }
            let hits = documents.map { document in
                SearchHit(document: document,
                          excerpt: contents[document.id].flatMap { Highlighter.excerpt($0, terms: parsed.highlightTerms) })
            }

            return SearchResults(hits: hits, total: total, categoryCounts: categoryCounts,
                                 highlightTerms: parsed.highlightTerms, elapsed: Date().timeIntervalSince(started))
        }
    }

    /// Path completions for a typed prefix
    public func suggestPaths(prefix: String, limit: Int = 20) async throws -> [String] {
        try await pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT rtrim(path, replace(path, '/', '')) AS directory FROM document
                WHERE path >= ? AND path < ? AND parentId IS NULL LIMIT ?
                """, arguments: [prefix, prefix + "\u{10FFFF}", limit])
        }
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}

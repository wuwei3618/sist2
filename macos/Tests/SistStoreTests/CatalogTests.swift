import Foundation
import Testing
import SistCore
@testable import SistStore

func makeCatalog() throws -> (Catalog, String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sist-store-\(UUID().uuidString)").path
    return (try Catalog(path: directory + "/catalog.sqlite"), directory)
}

func doc(_ path: String, parent: String? = nil, content: String? = nil, mime: String = "text/plain",
         size: Int64 = 10, mtime: Int64 = 1_700_000_000, title: String? = nil) -> ParseResult {
    ParseResult(document: ParsedDocument(
        path: path, parentPath: parent, name: path.lastPathComponentFast, ext: path.pathExtensionFast,
        mime: mime, size: size, mtime: mtime, title: title, content: content))
}

@Suite struct CJKSearchTests {
    let corpus: [(String, String)] = [
        ("/r/a.txt", "这是一个关于文档管理系统的说明"),
        ("/r/b.txt", "季度销售报告，包含华东地区数据"),
        ("/r/c.txt", "iPhone手机壳和配件"),
        ("/r/d.txt", "日本語のテキストを検索する"),
        ("/r/e.txt", "plain English text about reports"),
        ("/r/f.txt", "文字b混合"),
    ]

    func search(_ catalog: Catalog, _ text: String) async throws -> Set<String> {
        Set(try await catalog.search(SearchQuery(text: text)).hits.map(\.document.name))
    }

    @Test func substringsOfAnyLengthMatch() async throws {
        let (catalog, directory) = try makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let source = try await catalog.addSource(root: "/r")
        let scan = try await catalog.writer.beginScan(sourceId: source.id)
        try await catalog.writer.write(corpus.map { doc($0.0, content: $0.1) }, source: source, scanId: scan)

        #expect(try await search(catalog, "文档") == ["a.txt"])
        #expect(try await search(catalog, "文档管理系统") == ["a.txt"])
        #expect(try await search(catalog, "管理系") == ["a.txt"])
        #expect(try await search(catalog, "档") == ["a.txt"])
        #expect(try await search(catalog, "统") == ["a.txt"])
        #expect(try await search(catalog, "报告") == ["b.txt"])
        #expect(try await search(catalog, "报告 华东") == ["b.txt"])
        #expect(try await search(catalog, "报告 -华东") == [])
        #expect(try await search(catalog, "手机") == ["c.txt"])
        #expect(try await search(catalog, "iphone手机") == ["c.txt"])
        #expect(try await search(catalog, "テキスト") == ["d.txt"])
        #expect(try await search(catalog, "検索") == ["d.txt"])
        #expect(try await search(catalog, "文字b") == ["f.txt"])
        #expect(try await search(catalog, "字b") == ["f.txt"])
        // Characters that are each present, but not next to each other
        #expect(try await search(catalog, "文管") == [])
        #expect(try await search(catalog, "report*") == ["e.txt"])
        #expect(try await search(catalog, "REPORTS") == ["e.txt"])
    }

    @Test func excerptsQuoteTheOriginalText() async throws {
        let (catalog, directory) = try makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let source = try await catalog.addSource(root: "/r")
        let scan = try await catalog.writer.beginScan(sourceId: source.id)
        try await catalog.writer.write(corpus.map { doc($0.0, content: $0.1) }, source: source, scanId: scan)

        let results = try await catalog.search(SearchQuery(text: "销售报告"))
        let excerpt = try #require(results.hits.first?.excerpt)
        #expect(excerpt.segments.filter(\.highlighted).map(\.text) == ["销售报告"])
    }
}

@Suite struct IncrementalScanTests {
    @Test func unchangedFilesAreNotReparsedAndMissingOnesAreDeleted() async throws {
        let (catalog, directory) = try makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let source = try await catalog.addSource(root: "/r")
        let writer = catalog.writer

        // First scan: a file and an archive with two members
        let first = try await writer.beginScan(sourceId: source.id)
        let entries = [FileEntry(path: "/r/a.txt", mtime: 1, size: 10), FileEntry(path: "/r/z.zip", mtime: 1, size: 10)]
        #expect(try await writer.markUnchanged(entries, sourceId: source.id, scanId: first) == entries)
        try await writer.write([
            doc("/r/a.txt", content: "alpha"),
            doc("/r/z.zip", mime: "application/zip", mtime: 1),
            doc("/r/z.zip#/m1.txt", parent: "/r/z.zip", content: "member one"),
            doc("/r/z.zip#/m2.txt", parent: "/r/z.zip", content: "member two"),
        ].map { var r = $0; r.document.mtime = 1; return r }, source: source, scanId: first)
        #expect(try await writer.finishScan(sourceId: source.id, scanId: first, counters: ScanCounters()) == 0)

        // Second scan, nothing changed: nothing to parse, members kept although nobody saw them
        let second = try await writer.beginScan(sourceId: source.id)
        #expect(try await writer.markUnchanged(entries, sourceId: source.id, scanId: second).isEmpty)
        #expect(try await writer.finishScan(sourceId: source.id, scanId: second, counters: ScanCounters()) == 0)
        #expect(try await catalog.search(SearchQuery(text: "member")).total == 2)

        // Third scan: the archive changed and lost a member, a.txt is gone
        let third = try await writer.beginScan(sourceId: source.id)
        let changed = [FileEntry(path: "/r/z.zip", mtime: 2, size: 10)]
        #expect(try await writer.markUnchanged(changed, sourceId: source.id, scanId: third) == changed)
        try await writer.write([
            doc("/r/z.zip", mime: "application/zip", mtime: 2),
            doc("/r/z.zip#/m1.txt", parent: "/r/z.zip", content: "member one again"),
        ], source: source, scanId: third)
        // a.txt is deleted; m2 already went when the changed archive was written again
        #expect(try await writer.finishScan(sourceId: source.id, scanId: third, counters: ScanCounters()) == 1)

        let all = try await catalog.search(SearchQuery())
        #expect(Set(all.hits.map(\.document.path)) == ["/r/z.zip", "/r/z.zip#/m1.txt"])
        #expect(try await catalog.search(SearchQuery(text: "alpha")).total == 0)
        #expect(try await catalog.search(SearchQuery(text: "again")).total == 1)

        let ftsRows = try await catalog.pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM document_fts") }
        #expect(ftsRows == 2)
    }

    @Test func removingASourceRemovesEverything() async throws {
        let (catalog, directory) = try makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let source = try await catalog.addSource(root: "/r")
        let scan = try await catalog.writer.beginScan(sourceId: source.id)
        var withThumbnail = doc("/r/a.txt", content: "alpha")
        withThumbnail.thumbnails = [Data([1, 2, 3])]
        try await catalog.writer.write([withThumbnail], source: source, scanId: scan)
        #expect(try await catalog.thumbnail(documentId: 1) == Data([1, 2, 3]))

        try await catalog.removeSource(id: source.id)
        let counts = try await catalog.pool.read { db in
            try ["document", "document_fts", "content", "thumbnail"].map {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)") ?? -1
            }
        }
        #expect(counts == [0, 0, 0, 0])
    }

    @Test func duplicateSourcesAreRejected() async throws {
        let (catalog, directory) = try makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        _ = try await catalog.addSource(root: "/r/")
        await #expect(throws: CatalogError.self) {
            _ = try await catalog.addSource(root: "/r")
        }
    }
}

@Suite struct SearchFilterTests {
    func populate(_ catalog: Catalog) async throws -> Source {
        let source = try await catalog.addSource(root: "/r")
        let scan = try await catalog.writer.beginScan(sourceId: source.id)
        try await catalog.writer.write([
            doc("/r/docs/report.pdf", content: "annual report", mime: "application/pdf", size: 5_000, mtime: 1_600_000_000),
            doc("/r/docs/notes.txt", content: "report notes", size: 100, mtime: 1_700_000_000),
            doc("/r/photos/beach.jpg", content: nil, mime: "image/jpeg", size: 2_000_000, mtime: 1_650_000_000),
            doc("/r/photos/report-cover.png", content: nil, mime: "image/png", size: 50_000, mtime: 1_680_000_000),
        ], source: source, scanId: scan)
        return source
    }

    @Test func facetsIgnoreTheCategoryFilter() async throws {
        let (catalog, directory) = try makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        _ = try await populate(catalog)

        var query = SearchQuery(text: "report")
        query.categories = [.image]
        let results = try await catalog.search(query)
        #expect(results.hits.map(\.document.name) == ["report-cover.png"])
        #expect(results.categoryCounts == [.document: 1, .text: 1, .image: 1])
    }

    @Test func pathSizeDateAndSort() async throws {
        let (catalog, directory) = try makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        _ = try await populate(catalog)

        var query = SearchQuery()
        query.pathPrefix = "/r/photos"
        query.sort = .sizeLargest
        #expect(try await catalog.search(query).hits.map(\.document.name) == ["beach.jpg", "report-cover.png"])

        query = SearchQuery()
        query.minSize = 1_000
        query.maxSize = 100_000
        query.sort = .name
        #expect(try await catalog.search(query).hits.map(\.document.name) == ["report-cover.png", "report.pdf"])

        query = SearchQuery()
        query.modifiedAfter = Date(timeIntervalSince1970: 1_670_000_000)
        query.sort = .modifiedNewest
        #expect(try await catalog.search(query).hits.map(\.document.name) == ["notes.txt", "report-cover.png"])
    }

    @Test func nameWeighsMoreThanContent() async throws {
        let (catalog, directory) = try makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let source = try await catalog.addSource(root: "/r")
        let scan = try await catalog.writer.beginScan(sourceId: source.id)
        try await catalog.writer.write([
            doc("/r/other.txt", content: "budget budget budget and more words about the budget"),
            doc("/r/budget.txt", content: "unrelated words"),
        ], source: source, scanId: scan)
        #expect(try await catalog.search(SearchQuery(text: "budget")).hits.first?.document.name == "budget.txt")
    }

    @Test func tags() async throws {
        let (catalog, directory) = try makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        _ = try await populate(catalog)
        try await catalog.addTag("重要", to: 1)
        try await catalog.addTag("work", to: 1)
        try await catalog.addTag("work", to: 2)

        var query = SearchQuery()
        query.tags = ["work"]
        #expect(try await catalog.search(query).total == 2)
        query.tags = ["work", "重要"]
        #expect(try await catalog.search(query).hits.map(\.document.id) == [1])
        #expect(try await catalog.tags() == [TagCount(name: "work", count: 2), TagCount(name: "重要", count: 1)])
        #expect(try await catalog.document(id: 1)?.tags == ["work", "重要"])
    }

    @Test func stats() async throws {
        let (catalog, directory) = try makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let source = try await populate(catalog)
        let stats = try await catalog.stats(sourceId: source.id)
        #expect(stats.documentCount == 4)
        #expect(stats.totalSize == 2_055_100)
        #expect(Set(stats.topFolders.map(\.label)) == ["docs", "photos"])
        #expect(stats.byYear.map(\.label) == ["2020", "2022", "2023"])
    }
}

@Suite struct FolderAndScopeTests {
    func populate(_ catalog: Catalog) async throws -> (Source, Int64) {
        let source = try await catalog.addSource(root: "/r")
        let scan = try await catalog.writer.beginScan(sourceId: source.id)
        try await catalog.writer.write([
            doc("/r/top.txt", size: 1),
            doc("/r/a/x.txt", size: 10),
            doc("/r/a/b/y.txt", size: 100),
            doc("/r/a/b/z.zip", mime: "application/zip", size: 1000),
            doc("/r/a/b/z.zip#/inner.txt", parent: "/r/a/b/z.zip", size: 5000),
            doc("/r/c/w.txt", size: 10000),
        ], source: source, scanId: scan)
        try await catalog.writer.finishScan(sourceId: source.id, scanId: scan, counters: ScanCounters(),
                                            indexedOptions: source.options)
        return (source, scan)
    }

    @Test func folderTreeCountsFilesBelow() async throws {
        let (catalog, directory) = try makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (source, _) = try await populate(catalog)

        let root = try #require(try await catalog.folder(sourceId: source.id, path: "/r"))
        // Archive members are counted in their archive
        #expect(root.count == 5)
        #expect(root.size == 11111)
        #expect(root.hasSubfolders)

        let first = try await catalog.folders(sourceId: source.id, parent: "/r")
        #expect(first.map(\.name) == ["a", "c"])
        #expect(first.map(\.count) == [3, 1])
        #expect(first.map(\.hasSubfolders) == [true, false])
        #expect(try await catalog.folders(sourceId: source.id, parent: "/r/a").map(\.path) == ["/r/a/b"])
        #expect(try await catalog.folders(sourceId: source.id, parent: "/r/a/b").isEmpty)
    }

    @Test func scopedScansOnlyDeleteInsideTheirScopes() async throws {
        let (catalog, directory) = try makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (source, _) = try await populate(catalog)
        let writer = catalog.writer

        // Scans that see nothing: what they delete depends only on their scopes
        var scan = try await writer.beginScan(sourceId: source.id)
        #expect(try await writer.finishScan(sourceId: source.id, scanId: scan, counters: ScanCounters(),
                                            scopes: [ScanScope(path: "/r/a", recursive: false)]) == 1)
        #expect(try await catalog.search(SearchQuery()).hits.map(\.document.path).contains("/r/a/x.txt") == false)

        scan = try await writer.beginScan(sourceId: source.id)
        #expect(try await writer.finishScan(sourceId: source.id, scanId: scan, counters: ScanCounters(),
                                            scopes: [ScanScope(path: "/r/a", recursive: true)]) == 2)
        let left = Set(try await catalog.search(SearchQuery()).hits.map(\.document.path))
        // The archive took its member with it
        #expect(left == ["/r/top.txt", "/r/c/w.txt"])
        #expect(try await catalog.folders(sourceId: source.id, parent: "/r").map(\.name) == ["c"])

        // A scoped scan does not record the options as indexed
        #expect(try await catalog.source(id: source.id).indexedOptions == source.options)
    }

    @Test func migratingFromVersion1KeepsDocumentsAndBuildsFolders() async throws {
        let (catalog, directory) = try makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (source, _) = try await populate(catalog)
        try await catalog.pool.write { db in
            try db.execute(sql: "UPDATE document SET directory = NULL; DELETE FROM folder")
            // What the v2 migration runs on catalogs made before it
            try db.execute(sql: """
                UPDATE document SET directory = coalesce(nullif(rtrim(rtrim(path, replace(path, '/', '')), '/'), ''), '/')
                WHERE parentId IS NULL
                """)
            try CatalogWriter.rebuildFolders(db, sourceId: source.id, root: "/r")
        }
        #expect(try await catalog.folder(sourceId: source.id, path: "/r")?.count == 5)
        #expect(try await catalog.folders(sourceId: source.id, parent: "/r/a").map(\.path) == ["/r/a/b"])
    }
}

@Suite struct ScanOptionsTests {
    @Test func onlyExtractionSettingsRequireARebuild() {
        let base = ScanOptions()
        var walkOnly = base
        walkOnly.excludePattern = "/tmp/"
        walkOnly.maxDepth = 3
        walkOnly.threads = 2
        walkOnly.jobTimeout = 5
        #expect(!walkOnly.changesExtraction(comparedTo: base))

        for change in [{ (o: inout ScanOptions) in o.ocrImages = true },
                       { o in o.contentSizeLimit = 100 },
                       { o in o.thumbnailCount = 0 },
                       { o in o.archiveMode = .list },
                       { o in o.ocrLanguages = ["ja"] }] {
            var options = base
            change(&options)
            #expect(options.changesExtraction(comparedTo: base))
        }
    }
}

@Suite struct SchemaTests {
    @Test func contentlessDeleteNeedsSQLite343() {
        #expect(Schema.supportsContentlessDelete(version: "3.43.0"))
        #expect(Schema.supportsContentlessDelete(version: "3.45.1"))
        #expect(Schema.supportsContentlessDelete(version: "4.0.0"))
        #expect(!Schema.supportsContentlessDelete(version: "3.42.9"))
        #expect(!Schema.supportsContentlessDelete(version: "3.39.5"))
        #expect(!Schema.supportsContentlessDelete(version: ""))
    }

    @Test func fullTextIndexKeepsNoCopyOfTheText() async throws {
        let (catalog, directory) = try makeCatalog()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (sql, version) = try await catalog.pool.read { db in
            (try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'document_fts'") ?? "",
             try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "")
        }
        #expect(sql.contains("contentless_delete") == Schema.supportsContentlessDelete(version: version))

        // Rows still go away with their document
        let source = try await catalog.addSource(root: "/r")
        let scan = try await catalog.writer.beginScan(sourceId: source.id)
        try await catalog.writer.write([doc("/r/a.txt", content: "searchable words")], source: source, scanId: scan)
        #expect(try await catalog.search(SearchQuery(text: "searchable")).total == 1)
        try await catalog.removeSource(id: source.id)
        let rows = try await catalog.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM document_fts WHERE document_fts MATCH 'searchable'")
        }
        #expect(rows == 0)
    }
}

import ArgumentParser
import Foundation
import SistCore
import SistExtractors
import SistScan
import SistStore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct SistCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sist",
        abstract: "Index folders and search them. Shares its catalog with the Sist app.",
        subcommands: [Scan.self, Search.self, Similar.self, Folders.self, Extract.self, Sources.self, Remove.self,
                      Stats.self, Semantic.self])
}

struct CatalogOptions: ParsableArguments {
    @Option(help: "Catalog database")
    var db: String = Catalog.defaultPath

    func open() throws -> Catalog {
        try Catalog(path: (db as NSString).expandingTildeInPath)
    }
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add a folder to the catalog, or update it incrementally if it is already there.")

    @OptionGroup var catalog: CatalogOptions

    @Argument(help: "Folder to index")
    var path: String

    @Option(help: "Display name of the source")
    var name: String?

    @Option(name: .shortAndLong, help: "Parsers running at once (0: one per core)")
    var threads: Int?

    @Flag(name: .customLong("ocr"), inversion: .prefixedNo, help: "Recognize text in images and scanned PDFs")
    var ocr: Bool?

    @Option(help: "OCR languages, comma separated (e.g. zh-Hans,en-US)")
    var ocrLanguages: String?

    @Option(help: "Thumbnails per document (0 disables)")
    var thumbnails: Int?

    @Option(help: "Maximum characters of text kept per document")
    var contentSize: Int?

    @Option(help: "Archives: skip, list, shallow or recurse")
    var archive: String?

    @Flag(inversion: .prefixedNo, help: "Compute SHA-1 checksums")
    var checksums: Bool?

    @Option(help: "Regular expression of absolute paths to leave out")
    var exclude: String?

    @Option(help: "Maximum directory depth (-1: unlimited)")
    var depth: Int?

    @Option(help: "Seconds before a parser is killed")
    var timeout: Double?

    @Flag(help: "Parse in this process instead of sist-worker processes")
    var inProcess = false

    @Flag(help: "Parse every file again, changed or not")
    var rebuild = false

    @Option(help: "Only scan this folder of the source (repeatable)")
    var subpath: [String] = []

    @Flag(name: .shortAndLong, help: "Print warnings and errors")
    var verbose = false

    func run() async throws {
        let catalog = try catalog.open()
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path

        let existing = try await catalog.source(root: root)
        var options = existing?.options ?? ScanOptions()
        if let threads { options.threads = threads }
        if let ocr { options.ocrImages = ocr; options.ocrDocuments = ocr }
        if let ocrLanguages {
            options.ocrLanguages = ocrLanguages.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let thumbnails { options.thumbnailCount = thumbnails }
        if let contentSize { options.contentSizeLimit = contentSize }
        if let archive {
            guard let mode = ArchiveMode(rawValue: archive) else {
                throw ValidationError("--archive must be one of skip, list, shallow, recurse")
            }
            options.archiveMode = mode
        }
        if let checksums { options.computeChecksums = checksums }
        if let exclude { options.excludePattern = exclude }
        if let depth { options.maxDepth = depth }
        if let timeout { options.jobTimeout = timeout }

        let source: Source
        if let existing {
            try await catalog.updateSource(id: existing.id, name: name, options: options)
            source = try await catalog.source(id: existing.id)
        } else {
            source = try await catalog.addSource(root: root, name: name, options: options)
        }

        let verbose = self.verbose
        let started = Date()
        let coordinator = ScanCoordinator(catalog: catalog, isolation: inProcess ? .inProcess : .automatic)
        let scopes = subpath.isEmpty ? nil : subpath.map {
            ScanScope(path: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path,
                      recursive: true)
        }
        if source.needsRebuild && !rebuild {
            printError("The options changed in ways that affect parsing: every file is parsed again")
        }
        let counters = try await coordinator.scan(
            sourceId: source.id, mode: rebuild ? .rebuild : .incremental, scopes: scopes,
            log: { message in
                guard verbose || message.level >= .error else { return }
                printError("\n[\(message.level)] \(message.path): \(message.message)")
            },
            progress: { progress in
                let c = progress.counters
                printError("\r\(progress.phase.rawValue): \(c.walked) files, \(c.unchanged) unchanged, "
                           + "\(c.parsed) parsed, \(c.errors) errors   ", newline: false)
            })
        printError("")
        print("\(source.name): \(counters.walked) files, \(counters.parsed) parsed, "
              + "\(counters.unchanged) unchanged, \(counters.deleted) deleted, \(counters.errors) errors "
              + "in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search the catalog.")

    @OptionGroup var catalog: CatalogOptions

    @Argument(help: "Query: words, \"phrases\", prefix*, -exclude, a OR b, name:word")
    var query: [String] = []

    @Option(name: .shortAndLong, help: "Maximum results")
    var limit = 20

    @Option(help: "Only this kind: \(MimeCategory.allCases.map(\.rawValue).joined(separator: ", "))")
    var kind: [String] = []

    @Option(help: "Only below this folder")
    var path: String?

    @Option(help: "relevance, modifiedNewest, modifiedOldest, sizeLargest, sizeSmallest, name")
    var sort = "relevance"

    @Option(help: "At least this size: bytes, or with K, M, G (e.g. 10M)")
    var minSize: String?

    @Option(help: "At most this size")
    var maxSize: String?

    @Option(help: "Modified on or after this day (YYYY-MM-DD)")
    var after: String?

    @Option(help: "Modified before this day (YYYY-MM-DD)")
    var before: String?

    @Flag(help: "Print JSON")
    var json = false

    @Flag(help: "Also match by meaning (needs `sist semantic --on` and an up-to-date semantic index)")
    var semantic = false

    @Flag(help: "Match by meaning only")
    var semanticOnly = false

    func run() async throws {
        let catalog = try catalog.open()
        var search = SearchQuery(text: query.joined(separator: " "))
        if semantic || semanticOnly {
            search.semantic = try queryEmbedding(search.text)
            search.semanticOnly = semanticOnly
        }
        search.limit = limit
        search.categories = Set(kind.compactMap(MimeCategory.init(rawValue:)))
        search.pathPrefix = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        search.sort = SearchSort(rawValue: sort) ?? .relevance
        search.minSize = try minSize.map(parseSize)
        search.maxSize = try maxSize.map(parseSize)
        search.modifiedAfter = try after.map(parseDay)
        search.modifiedBefore = try before.map(parseDay)
        let results = try await catalog.search(search)
        try await printResults(results, query: search, catalog: catalog, json: json)
    }
}

/// The query's vector, with the model the documents' passages were embedded with
func queryEmbedding(_ text: String) throws -> Embedding {
    guard let embedder = SemanticModels.textEmbedder() else {
        throw ValidationError("Semantic search needs macOS")
    }
    do {
        guard let embedding = try embedder.embed(text) else {
            throw ValidationError("No embedding model for the language of \"\(text)\"")
        }
        return embedding
    } catch EmbeddingError.modelUnavailable {
        throw ValidationError("The embedding model for this language is being downloaded; try again later")
    }
}

func printResults(_ results: SearchResults, query search: SearchQuery, catalog: Catalog, json: Bool) async throws {
    if json {
        let hits: [[String: Any]] = results.hits.map { hit in
            var object: [String: Any] = [
                "id": hit.document.id, "path": hit.document.path, "name": hit.document.name,
                "size": hit.document.size, "mtime": hit.document.mtime, "category": hit.document.category.rawValue,
            ]
            object["mime"] = hit.document.mime
            object["title"] = hit.document.title
            object["excerpt"] = hit.excerpt?.plainText
            return object
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["total": results.total, "hits": hits], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return
    }

    let color = isatty(STDOUT_FILENO) != 0
    func render(_ snippet: Snippet) -> String {
        snippet.segments.map { segment in
            segment.highlighted && color ? "\u{1B}[1;33m\(segment.text)\u{1B}[0m" : segment.text
        }.joined()
    }

    for hit in results.hits {
        let document = hit.document
        let size = ByteCountFormatter.string(fromByteCount: document.size, countStyle: .file)
        let date = ISO8601DateFormatter.string(from: document.modificationDate, timeZone: .current,
                                               formatOptions: [.withFullDate])
        let similarity = hit.similarity.map { String(format: ", similarity %.2f", $0) } ?? ""
        print(render(Highlighter.highlight(document.name, terms: results.highlightTerms))
              + "  [\(document.category.rawValue), \(size), \(date)\(similarity)]")
        print("  \(document.path)")
        // A semantic match shows the passage that matched, highlighted or not
        if let excerpt = hit.excerpt, excerpt.hasHighlights || hit.similarity != nil {
            print("  " + render(excerpt))
        }
    }
    print("\(results.total) results in \(String(format: "%.0f", results.elapsed * 1000)) ms")
    if results.total == 0, search.semantic == nil, let suggestion = try await catalog.spellingSuggestion(for: search.text) {
        print("Did you mean: \(suggestion)")
    }
}

struct Similar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Images that look like an indexed image (needs `sist semantic --on`).")

    @OptionGroup var catalog: CatalogOptions

    @Argument(help: "An indexed image, or an image inside an archive (archive.zip#/photo.jpg)")
    var path: String

    @Option(name: .shortAndLong, help: "Maximum results")
    var limit = 20

    @Flag(help: "Print JSON")
    var json = false

    func run() async throws {
        let catalog = try catalog.open()
        let path = path.contains("#/") ? path : URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        guard let id = try await catalog.documentId(path: path) else {
            throw ValidationError("\(path) is not in the catalog")
        }
        guard let embedding = try await catalog.embedding(documentId: id, kind: .image) else {
            throw ValidationError("\(path) has not been analysed: run `sist semantic --update`")
        }
        var query = SearchQuery()
        query.semantic = embedding
        query.semanticOnly = true
        query.excludedDocument = id
        query.limit = limit
        try await printResults(try await catalog.search(query), query: query, catalog: catalog, json: json)
    }
}

struct Semantic: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Semantic search: turn it on or off, show its progress, or bring it up to date.",
        discussion: """
            With semantic search on, passages of each document's text get vectors from the system's \
            language models, and images a feature print and labels (macOS). The app and its background \
            agent keep this up to date after each scan; --update does it now.
            """)

    @OptionGroup var catalog: CatalogOptions

    @Flag(name: .customLong("on"), help: "Turn semantic search on")
    var turnOn = false

    @Flag(name: .customLong("off"), help: "Turn it off (vectors already computed stay)")
    var turnOff = false

    @Flag(help: "Analyse the documents not analysed yet")
    var update = false

    func run() async throws {
        let catalog = try catalog.open()
        if turnOn || turnOff {
            try await catalog.setSetting(Catalog.semanticSearchSetting, turnOn ? "1" : nil)
        }
        if update {
            guard await catalog.isSemanticSearchEnabled() else {
                throw ValidationError("Semantic search is off: sist semantic --on")
            }
            let text = SemanticModels.textEmbedder()
            let images = SemanticModels.imageAnalyzer()
            guard text != nil || images != nil else {
                throw ValidationError("Semantic search needs macOS")
            }
            let done = try await SemanticIndexer(catalog: catalog, text: text, images: images).run { done, pending in
                FileHandle.standardError.write(Data("\r\(done)/\(pending)".utf8))
            }
            FileHandle.standardError.write(Data("\n".utf8))
            print("Analysed \(done) documents")
        }
        let status = try await catalog.semanticStatus()
        print("Semantic search: \(await catalog.isSemanticSearchEnabled() ? "on" : "off")")
        for kind in EmbeddingKind.allCases {
            print("  \(kind.rawValue): \(status.indexed[kind] ?? 0) analysed, \(status.pending[kind] ?? 0) pending")
        }
        print("  vectors: \(status.vectors)")
    }
}

struct Folders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the folders of an indexed folder, with the number and size of the files below each.")

    @OptionGroup var catalog: CatalogOptions

    @Argument(help: "Folder inside a source (default: the root of every source)")
    var path: String?

    func run() async throws {
        let catalog = try catalog.open()
        let sources = try await catalog.sources().map(\.source)
        let wanted = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        for source in sources {
            let parent = wanted ?? source.root
            guard parent == source.root || parent.hasPrefix(source.root == "/" ? "/" : source.root + "/") else { continue }
            if let folder = try await catalog.folder(sourceId: source.id, path: parent) {
                print("\(folder.path)  \(folder.count) files, \(bytes(folder.size))")
            }
            for folder in try await catalog.folders(sourceId: source.id, parent: parent) {
                let marker = folder.hasSubfolders ? "+" : " "
                print("  \(marker) \(folder.name.padding(toLength: 30, withPad: " ", startingAt: 0)) "
                      + "\(String(folder.count).padding(toLength: 8, withPad: " ", startingAt: 0)) \(bytes(folder.size))")
            }
        }
    }
}

struct Extract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write an archive member to a file or stdout, by its path in the catalog (archive.zip#/dir/file).")

    @Argument(help: "Member path, as `sist search` prints it")
    var path: String

    @Option(name: .shortAndLong, help: "Output file (default: stdout)")
    var output: String?

    func run() throws {
        let data = try ArchiveMemberReader.data(forPath: path)
        if let output {
            try data.write(to: URL(fileURLWithPath: output))
        } else {
            FileHandle.standardOutput.write(data)
        }
    }
}

struct Sources: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List indexed folders.")

    @OptionGroup var catalog: CatalogOptions

    func run() async throws {
        for info in try await catalog.open().sources() {
            let size = ByteCountFormatter.string(fromByteCount: info.totalSize, countStyle: .file)
            let scanned = info.source.lastScanAt.map { "last scan \($0)" } ?? "never scanned"
            print("\(info.source.id)\t\(info.source.name)\t\(info.documentCount) files\t\(size)\t\(scanned)\t\(info.source.root)")
        }
    }
}

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove a source and its documents from the catalog.")

    @OptionGroup var catalog: CatalogOptions

    @Argument(help: "Source id (see `sist sources`)")
    var id: Int64

    func run() async throws {
        let catalog = try catalog.open()
        let source = try await catalog.source(id: id)
        try await catalog.removeSource(id: id)
        print("Removed \(source.name) (\(source.root))")
    }
}

struct Stats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what the catalog holds.")

    @OptionGroup var catalog: CatalogOptions

    @Option(help: "Source id; all sources when omitted")
    var source: Int64?

    func run() async throws {
        let stats = try await catalog.open().stats(sourceId: source)
        func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

        print("\(stats.documentCount) files, \(size(stats.totalSize))")
        print("\nBy kind:")
        for bucket in stats.byCategory {
            print("  \(bucket.label.padding(toLength: 12, withPad: " ", startingAt: 0))\(bucket.count)\t\(size(bucket.size))")
        }
        print("\nBy size:")
        for bucket in stats.sizeHistogram {
            print("  \(bucket.label.padding(toLength: 12, withPad: " ", startingAt: 0))\(bucket.count)")
        }
        print("\nBy year:")
        for bucket in stats.byYear {
            print("  \(bucket.label)\t\(bucket.count)\t\(size(bucket.size))")
        }
        if !stats.topFolders.isEmpty {
            print("\nLargest folders:")
            for bucket in stats.topFolders.prefix(10) {
                print("  \(bucket.label.padding(toLength: 30, withPad: " ", startingAt: 0))\(size(bucket.size))")
            }
        }
    }
}

func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

func parseSize(_ text: String) throws -> Int64 {
    let units: [Character: Int64] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40]
    var digits = text.uppercased().trimmingCharacters(in: .whitespaces)
    if digits.hasSuffix("B") { digits.removeLast() }
    var multiplier: Int64 = 1
    if let unit = digits.last, let value = units[unit] {
        multiplier = value
        digits.removeLast()
    }
    guard let number = Double(digits) else { throw ValidationError("Not a size: \(text)") }
    return Int64(number * Double(multiplier))
}

func parseDay(_ text: String) throws -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: text) else { throw ValidationError("Not a day (YYYY-MM-DD): \(text)") }
    return date
}

func printError(_ message: String, newline: Bool = true) {
    FileHandle.standardError.write(Data((message + (newline ? "\n" : "")).utf8))
}

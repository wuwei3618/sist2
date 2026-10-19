import ArgumentParser
import Foundation
import SistCore
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
        subcommands: [Scan.self, Search.self, Sources.self, Remove.self, Stats.self])
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
        let counters = try await coordinator.scan(
            sourceId: source.id,
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

    @Flag(help: "Print JSON")
    var json = false

    func run() async throws {
        let catalog = try catalog.open()
        var search = SearchQuery(text: query.joined(separator: " "))
        search.limit = limit
        search.categories = Set(kind.compactMap(MimeCategory.init(rawValue:)))
        search.pathPrefix = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        search.sort = SearchSort(rawValue: sort) ?? .relevance
        let results = try await catalog.search(search)

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
            print(render(Highlighter.highlight(document.name, terms: results.highlightTerms))
                  + "  [\(document.category.rawValue), \(size), \(date)]")
            print("  \(document.path)")
            if let excerpt = hit.excerpt, excerpt.hasHighlights {
                print("  " + render(excerpt))
            }
        }
        print("\(results.total) results in \(String(format: "%.0f", results.elapsed * 1000)) ms")
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

func printError(_ message: String, newline: Bool = true) {
    FileHandle.standardError.write(Data((message + (newline ? "\n" : "")).utf8))
}

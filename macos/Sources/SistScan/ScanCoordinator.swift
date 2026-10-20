import Foundation
import SistCore
import SistExtractors
import SistStore

public struct ScanProgress: Sendable, Hashable {
    public enum Phase: String, Sendable {
        case walking, finishing, completed
    }

    public var sourceId: Int64
    public var scanId: Int64
    public var phase: Phase
    public var counters: ScanCounters
    /// Files sent to the parsers that have not come back yet
    public var queued: Int
    public var currentPath: String?
    public var startedAt: Date
    /// Every file is parsed again: an explicit rebuild, or options that change parsing
    public var isRebuild: Bool
    /// The directories scanned, nil for the whole source
    public var scopes: [ScanScope]?
}

public enum ScanMode: Sendable {
    /// Parse new and changed files only
    case incremental
    /// Parse every file again
    case rebuild
}

public enum ParserIsolation: Sendable {
    /// `sist-worker` processes when the executable can be found, in-process otherwise
    case automatic
    case inProcess
    case subprocess(URL)
}

/// Runs a scan of one source: the walk feeds batches to the incremental check, changed files go
/// to the parser pool, and results are written by this task alone, so there is a single writer
/// as in sist2's scan master.
public struct ScanCoordinator: Sendable {
    public let catalog: Catalog
    public let isolation: ParserIsolation

    static let walkBatchSize = 256
    static let writeBatchSize = 64

    public init(catalog: Catalog, isolation: ParserIsolation = .automatic) {
        self.catalog = catalog
        self.isolation = isolation
    }

    /// Scans a source, or only `scopes` of it. A rebuild, explicit or because the options changed
    /// in ways that affect parsing since the last complete scan, always covers the whole source,
    /// and so does the first scan of a source.
    @discardableResult
    public func scan(sourceId: Int64, mode: ScanMode = .incremental, scopes: [ScanScope]? = nil,
                     log: LogHandler? = nil,
                     progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanCounters {
        let source = try await catalog.source(id: sourceId)
        let rebuild = mode == .rebuild || source.needsRebuild
        var plannedScopes: [ScanScope]? = nil
        if let scopes, !rebuild, source.indexedOptions != nil {
            plannedScopes = Self.plan(scopes, source: source)
            if plannedScopes?.isEmpty == true {
                return ScanCounters()
            }
        }

        let writer = catalog.writer
        let scanId = try await writer.beginScan(sourceId: sourceId)
        let pool = makePool(options: source.options, log: log)
        var counters = ScanCounters()
        var state = ScanProgress(sourceId: sourceId, scanId: scanId, phase: .walking, counters: counters,
                                 queued: 0, currentPath: nil, startedAt: Date(), isRebuild: rebuild,
                                 scopes: plannedScopes)

        do {
            try await run(source: source, scopes: plannedScopes, rebuild: rebuild, scanId: scanId, pool: pool,
                          writer: writer, log: log, counters: &counters, state: &state, progress: progress)
            state.phase = .finishing
            state.counters = counters
            progress?(state)
            counters.deleted = try await writer.finishScan(
                sourceId: sourceId, scanId: scanId, counters: counters, scopes: plannedScopes,
                indexedOptions: plannedScopes == nil ? source.options : nil)
        } catch {
            await pool.shutdown()
            let status: ScanStatus = error is CancellationError ? .cancelled : .failed
            // GRDB will not start a write from a cancelled task, so the bookkeeping runs detached
            let finalCounters = counters
            _ = try? await Task.detached {
                try await writer.abortScan(scanId: scanId, status: status, counters: finalCounters)
            }.value
            throw error
        }

        await pool.shutdown()
        state.phase = .completed
        state.counters = counters
        state.currentPath = nil
        progress?(state)
        return counters
    }

    func makePool(options: ScanOptions, log: LogHandler?) -> any ParserPool {
        switch isolation {
        case .inProcess:
            return InProcessParserPool(options: options, log: log)
        case .subprocess(let executable):
            return SubprocessParserPool(executable: executable, options: options, log: log)
        case .automatic:
            if let executable = WorkerLocator.find() {
                return SubprocessParserPool(executable: executable, options: options, log: log)
            }
            log?(LogMessage(level: .warning, path: "",
                            message: "\(WorkerLocator.executableName) not found, parsing in-process"))
            return InProcessParserPool(options: options, log: log)
        }
    }

    private func run(source: Source, scopes: [ScanScope]?, rebuild: Bool, scanId: Int64, pool: any ParserPool,
                     writer: CatalogWriter, log: LogHandler?, counters: inout ScanCounters,
                     state: inout ScanProgress, progress: (@Sendable (ScanProgress) -> Void)?) async throws {
        let ignoreList = IgnoreList.load(root: source.root)
        let targets: [(root: String, options: ScanOptions)] = scopes.map { scopes in
            scopes.compactMap { scope in Self.walkOptions(for: scope, source: source, ignoreList: ignoreList).map { (scope.path, $0) } }
        } ?? [(source.root, source.options)]

        var pending: [ParseResult] = []
        var inFlight = 0
        var walkErrors = 0
        var lastReport = Date.distantPast

        func report(force: Bool = false) {
            guard let progress, force || Date().timeIntervalSince(lastReport) > 0.25 else { return }
            lastReport = Date()
            state.counters = counters
            state.counters.errors += walkErrors
            state.queued = inFlight
            progress(state)
        }

        func absorb(_ job: ParseJobResult) {
            inFlight -= 1
            counters.parsed += 1
            var results = job.results
            if let error = job.error {
                counters.errors += 1
                log?(LogMessage(level: .error, path: job.entry.path, message: error))
            }
            // A file always gets a row, even when its parser crashed: it can still be found by name
            if let index = results.lastIndex(where: { $0.document.path == job.entry.path }) {
                if let error = job.error, results[index].document.error == nil {
                    results[index].document.error = error
                }
            } else {
                results.insert(Self.fallbackResult(for: job.entry, error: job.error ?? "No document produced"), at: 0)
            }
            pending += results
            state.currentPath = job.entry.path
        }

        try await withThrowingTaskGroup(of: ParseJobResult.self) { group in
            for target in targets {
                let walker: DirectoryWalker
                do {
                    walker = try DirectoryWalker(root: target.root, options: target.options, ignoreList: ignoreList) {
                        path, message in log?(LogMessage(level: .warning, path: path, message: message))
                    }
                } catch where scopes != nil {
                    // The directory is gone: finishScan deletes what the catalog had in it
                    continue
                }
                defer { walkErrors += walker.errorCount }

                while true {
                    try Task.checkCancellation()
                    let batch = walker.next(batch: Self.walkBatchSize)
                    if batch.isEmpty { break }
                    counters.walked += batch.count

                    let changed = rebuild
                        ? batch : try await writer.markUnchanged(batch, sourceId: source.id, scanId: scanId)
                    counters.unchanged += batch.count - changed.count

                    for entry in changed {
                        // Keep every parser busy, without queueing the whole tree
                        while inFlight >= pool.capacity * 2, let job = try await group.next() {
                            absorb(job)
                        }
                        if pending.count >= Self.writeBatchSize {
                            try await writer.write(pending, source: source, scanId: scanId)
                            pending.removeAll(keepingCapacity: true)
                        }
                        group.addTask { await pool.parse(entry) }
                        inFlight += 1
                        report()
                    }
                    report()
                }
            }

            while let job = try await group.next() {
                absorb(job)
                if pending.count >= Self.writeBatchSize {
                    try await writer.write(pending, source: source, scanId: scanId)
                    pending.removeAll(keepingCapacity: true)
                }
                report()
            }
        }

        try await writer.write(pending, source: source, scanId: scanId)
        counters.errors += walkErrors
        report(force: true)
    }

    /// Normalizes scopes: inside the source, packages replaced by the folder holding them, and
    /// none inside a recursive one. nil when they amount to the whole source.
    static func plan(_ scopes: [ScanScope], source: Source) -> [ScanScope]? {
        let root = source.root
        var planned = Set<ScanScope>()
        for scope in scopes {
            var path = (scope.path as NSString).standardizingPath
            while path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            guard let components = relativeComponents(of: path, root: root) else { continue }
            var recursive = scope.recursive

            // A package is one document: a change inside it rescans the folder holding it
            if source.options.treatPackagesAsFiles {
                var ancestor = root
                for component in components {
                    ancestor = (ancestor as NSString).appendingPathComponent(component)
                    if DirectoryWalker.isPackage(path: ancestor, name: component) {
                        path = (ancestor as NSString).deletingLastPathComponent
                        recursive = false
                        break
                    }
                }
            }

            if recursive && path == root {
                return nil
            }
            planned.insert(ScanScope(path: path, recursive: recursive))
        }

        let recursivePaths = planned.filter(\.recursive).map(\.path)
        return planned.filter { scope in
            !recursivePaths.contains { other in
                if scope.recursive && other == scope.path { return false }
                return scope.path == other || scope.path.hasPrefix(other == "/" ? "/" : other + "/")
            }
        }.sorted { $0.path < $1.path }
    }

    /// Walk options for a scope, or nil when the source's rules leave it out: a hidden, ignored or
    /// excluded directory on the way from the root, or beyond the depth limit.
    static func walkOptions(for scope: ScanScope, source: Source, ignoreList: IgnoreList) -> ScanOptions? {
        guard let components = relativeComponents(of: scope.path, root: source.root) else { return nil }
        var options = source.options
        let exclude = options.excludePattern.flatMap { try? NSRegularExpression(pattern: $0) }
        var path = source.root
        for component in components {
            path = (path as NSString).appendingPathComponent(component)
            if options.skipHiddenFiles && component.hasPrefix(".") { return nil }
            if ignoreList.isIgnored(path, isDirectory: true) { return nil }
            if let exclude, exclude.firstMatch(in: path, range: NSRange(path.startIndex..<path.endIndex, in: path)) != nil {
                return nil
            }
        }
        // Files directly in the root are at depth 0
        let depth = components.count
        if options.maxDepth >= 0 {
            guard depth <= options.maxDepth else { return nil }
            options.maxDepth = scope.recursive ? options.maxDepth - depth : 0
        } else if !scope.recursive {
            options.maxDepth = 0
        }
        return options
    }

    /// Path components below the root, nil when `path` is not inside it.
    static func relativeComponents(of path: String, root: String) -> [String]? {
        if path == root { return [] }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }

    static func fallbackResult(for entry: FileEntry, error: String) -> ParseResult {
        let name = entry.path.lastPathComponentFast
        let ext = name.pathExtensionFast
        return ParseResult(document: ParsedDocument(
            path: entry.path, name: name, ext: ext, mime: MimeTypes.mime(forExtension: ext),
            size: entry.size, mtime: entry.mtime, error: error))
    }
}

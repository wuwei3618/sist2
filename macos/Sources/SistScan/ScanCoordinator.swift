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

    @discardableResult
    public func scan(sourceId: Int64, log: LogHandler? = nil,
                     progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanCounters {
        let source = try await catalog.source(id: sourceId)
        let writer = catalog.writer
        let scanId = try await writer.beginScan(sourceId: sourceId)
        let pool = makePool(options: source.options, log: log)
        var counters = ScanCounters()
        var state = ScanProgress(sourceId: sourceId, scanId: scanId, phase: .walking, counters: counters,
                                 queued: 0, currentPath: nil, startedAt: Date())

        do {
            try await run(source: source, scanId: scanId, pool: pool, writer: writer, log: log,
                          counters: &counters, state: &state, progress: progress)
            state.phase = .finishing
            state.counters = counters
            progress?(state)
            counters.deleted = try await writer.finishScan(sourceId: sourceId, scanId: scanId, counters: counters)
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

    private func run(source: Source, scanId: Int64, pool: any ParserPool, writer: CatalogWriter, log: LogHandler?,
                     counters: inout ScanCounters, state: inout ScanProgress,
                     progress: (@Sendable (ScanProgress) -> Void)?) async throws {
        let walker = try DirectoryWalker(root: source.root, options: source.options) { path, message in
            log?(LogMessage(level: .warning, path: path, message: message))
        }
        var pending: [ParseResult] = []
        var inFlight = 0
        var lastReport = Date.distantPast

        func report(force: Bool = false) {
            guard let progress, force || Date().timeIntervalSince(lastReport) > 0.25 else { return }
            lastReport = Date()
            state.counters = counters
            state.counters.errors += walker.errorCount
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
            if !results.contains(where: { $0.document.path == job.entry.path }) {
                results.insert(Self.fallbackResult(for: job.entry, error: job.error ?? "No document produced"), at: 0)
            }
            pending += results
            state.currentPath = job.entry.path
        }

        try await withThrowingTaskGroup(of: ParseJobResult.self) { group in
            while true {
                try Task.checkCancellation()
                let batch = walker.next(batch: Self.walkBatchSize)
                if batch.isEmpty { break }
                counters.walked += batch.count

                let changed = try await writer.markUnchanged(batch, sourceId: source.id, scanId: scanId)
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
        counters.errors += walker.errorCount
        report(force: true)
    }

    static func fallbackResult(for entry: FileEntry, error: String) -> ParseResult {
        let name = entry.path.lastPathComponentFast
        let ext = name.pathExtensionFast
        return ParseResult(document: ParsedDocument(
            path: entry.path, name: name, ext: ext, mime: MimeTypes.mime(forExtension: ext),
            size: entry.size, mtime: entry.mtime, error: error))
    }
}

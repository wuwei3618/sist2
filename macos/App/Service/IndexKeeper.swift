import Foundation
import SistCore
import SistExtractors
import SistScan
import SistStore

/// Keeps the catalog up to date: watches each source with FSEvents and has a ScanScheduler scan
/// what changed; after scans, brings the semantic index up to date when semantic search is on.
/// The background agent runs one; so does the app while the agent is off.
@MainActor
public final class IndexKeeper {
    public let catalog: Catalog
    public let scheduler: ScanScheduler
    private var watchers: [Int64: FileSystemWatcher] = [:]
    private let textEmbedder = SemanticModels.textEmbedder()
    private let imageAnalyzer = SemanticModels.imageAnalyzer()
    private var semanticTask: Task<Void, Never>?
    private var semanticAgain = false

    /// Whether folders are watched; scans asked for run either way
    public var watching = true

    /// The scheduler's events reach the keeper through this, set once the keeper exists
    private final class Link: @unchecked Sendable {
        weak var keeper: IndexKeeper?
    }

    public init(catalog: Catalog, isolation: ParserIsolation = .automatic,
                events: @escaping @Sendable (ScanScheduler.Event) -> Void) {
        self.catalog = catalog
        let link = Link()
        scheduler = ScanScheduler(catalog: catalog, isolation: isolation) { event in
            events(event)
            if case .finished = event {
                Task { @MainActor in link.keeper?.updateSemanticIndex() }
            }
        }
        link.keeper = self
    }

    /// Watches the catalog's sources, and only them
    public func reloadSources() async {
        guard let sources = try? await catalog.sources() else { return }
        let roots = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.source.root) })
        for (id, watcher) in watchers where !watching || roots[id] == nil {
            watcher.stop()
            watchers[id] = nil
        }
        for id in await scheduler.scanning where roots[id] == nil {
            await scheduler.forget(id)
        }
        updateSemanticIndex()
        guard watching else { return }
        // The catalog may live inside a watched folder: its own writes must not trigger scans
        let catalogDirectory = (catalog.path as NSString).deletingLastPathComponent
        let scheduler = scheduler
        for (id, root) in roots where watchers[id] == nil {
            let watcher = FileSystemWatcher(path: root, ignoring: [catalogDirectory]) { events in
                Task { await scheduler.changed(id, events) }
            }
            watcher.start()
            watchers[id] = watcher
        }
    }

    /// Analyses what is pending for semantic search, if it is on; once at a time, again after
    /// the current run if asked meanwhile
    public func updateSemanticIndex() {
        guard semanticTask == nil else {
            semanticAgain = true
            return
        }
        let catalog = catalog
        let indexer = SemanticIndexer(catalog: catalog, text: textEmbedder, images: imageAnalyzer)
        semanticTask = Task { [weak self] in
            repeat {
                self?.semanticAgain = false
                guard await catalog.isSemanticSearchEnabled() else { break }
                _ = try? await indexer.run()
            } while self?.semanticAgain == true && !Task.isCancelled
            self?.semanticTask = nil
        }
    }

    public func stop() async {
        for watcher in watchers.values {
            watcher.stop()
        }
        watchers = [:]
        semanticTask?.cancel()
        await scheduler.cancelAll()
    }
}

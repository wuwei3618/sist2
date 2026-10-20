import Foundation
import SistCore
import SistScan
import SistStore

/// Keeps the catalog up to date: watches each source with FSEvents and has a ScanScheduler scan
/// what changed. The background agent runs one; so does the app while the agent is off.
@MainActor
public final class IndexKeeper {
    public let catalog: Catalog
    public let scheduler: ScanScheduler
    private var watchers: [Int64: FileSystemWatcher] = [:]

    /// Whether folders are watched; scans asked for run either way
    public var watching = true

    public init(catalog: Catalog, isolation: ParserIsolation = .automatic,
                events: @escaping @Sendable (ScanScheduler.Event) -> Void) {
        self.catalog = catalog
        scheduler = ScanScheduler(catalog: catalog, isolation: isolation, observer: events)
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

    public func stop() async {
        for watcher in watchers.values {
            watcher.stop()
        }
        watchers = [:]
        await scheduler.cancelAll()
    }
}

import Foundation
import SistCore
import SistStore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Keeps scans in order: one at a time per source, scans asked for meanwhile run after it
/// (merged into one), and file changes become scans of the folders they touched once things have
/// been quiet for `rescanDelay`. Used by whichever process does the scanning: the app, or the
/// background agent when it is enabled.
public actor ScanScheduler {
    public enum Event: Sendable {
        case progress(ScanProgress)
        case finished(sourceId: Int64, error: String?)
    }

    struct Request {
        var mode: ScanMode
        /// nil for the whole source
        var scopes: [ScanScope]?

        mutating func merge(_ other: Request) {
            if other.mode == .rebuild {
                mode = .rebuild
            }
            if let mine = scopes, let theirs = other.scopes {
                scopes = mine + theirs
            } else {
                scopes = nil
            }
        }
    }

    private let catalog: Catalog
    private let coordinator: ScanCoordinator
    private let rescanDelay: Duration
    private let observer: @Sendable (Event) -> Void
    private var running: [Int64: Task<Void, Never>] = [:]
    private var queued: [Int64: Request] = [:]
    private var changes: [Int64: [FileChange]] = [:]
    private var timers: [Int64: Task<Void, Never>] = [:]

    public init(catalog: Catalog, isolation: ParserIsolation = .automatic, rescanDelay: Duration = .seconds(10),
                observer: @escaping @Sendable (Event) -> Void) {
        self.catalog = catalog
        coordinator = ScanCoordinator(catalog: catalog, isolation: isolation)
        self.rescanDelay = rescanDelay
        self.observer = observer
    }

    /// Sources being scanned
    public var scanning: Set<Int64> { Set(running.keys) }

    public func scan(_ id: Int64, mode: ScanMode = .incremental, scopes: [ScanScope]? = nil) {
        let request = Request(mode: mode, scopes: scopes)
        guard running[id] == nil else {
            if var pending = queued[id] {
                pending.merge(request)
                queued[id] = pending
            } else {
                queued[id] = request
            }
            return
        }
        start(id, request)
    }

    /// Files changed under a source: rescanned once no more changes come for `rescanDelay`, or
    /// after the scan in progress
    public func changed(_ id: Int64, _ events: [FileChange]) {
        guard !events.isEmpty else { return }
        changes[id, default: []] += events
        if running[id] == nil {
            scheduleRescan(id)
        }
    }

    public func cancel(_ id: Int64) {
        queued[id] = nil
        timers.removeValue(forKey: id)?.cancel()
        running[id]?.cancel()
    }

    public func cancelAll() {
        for id in Set(running.keys).union(timers.keys) {
            cancel(id)
        }
    }

    /// The source was removed
    public func forget(_ id: Int64) {
        cancel(id)
        changes[id] = nil
    }

    private func start(_ id: Int64, _ request: Request) {
        timers.removeValue(forKey: id)?.cancel()
        // A scan of the whole source covers every change seen so far
        if request.scopes == nil {
            changes[id] = nil
        }
        let coordinator = coordinator
        let observer = observer
        running[id] = Task {
            var failure: String?
            do {
                try await coordinator.scan(sourceId: id, mode: request.mode, scopes: request.scopes,
                                           progress: { observer(.progress($0)) })
            } catch is CancellationError {
            } catch {
                failure = String(describing: error)
            }
            self.finished(id, error: failure)
        }
    }

    private func finished(_ id: Int64, error: String?) {
        running[id] = nil
        observer(.finished(sourceId: id, error: error))
        if let next = queued.removeValue(forKey: id) {
            start(id, next)
        } else if changes[id]?.isEmpty == false {
            scheduleRescan(id)
        }
    }

    private func scheduleRescan(_ id: Int64) {
        timers[id]?.cancel()
        let delay = rescanDelay
        timers[id] = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.rescanChanges(id)
        }
    }

    private func rescanChanges(_ id: Int64) async {
        timers[id] = nil
        guard let root = try? await catalog.source(id: id).root else {
            changes[id] = nil
            return
        }
        // Another scan may have started while the source was read; it picks the changes up after
        guard running[id] == nil, let events = changes.removeValue(forKey: id), !events.isEmpty else { return }
        scan(id, scopes: ChangeScopes.scopes(for: events, root: root))
    }
}

/// Which process scans. The background agent holds this lock for as long as it runs; the app
/// scans by itself only while it can hold it, and otherwise leaves scanning to the agent. An
/// advisory `flock` on a file next to the catalog: the system drops it when the holder exits,
/// however it exits.
public final class ScanLock: @unchecked Sendable {
    public let path: String
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    public init(catalogPath: String) {
        path = catalogPath + ".scanner"
    }

    deinit {
        release()
    }

    public var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0
    }

    /// Takes the lock unless another process (or another ScanLock) has it
    public func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor < 0 else { return true }
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    /// Whether someone else holds the lock
    public static func isHeldElsewhere(catalogPath: String) -> Bool {
        let probe = ScanLock(catalogPath: catalogPath)
        guard probe.tryAcquire() else { return true }
        probe.release()
        return false
    }
}

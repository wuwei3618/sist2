import Foundation
import Testing
import SistCore
import SistStore
@testable import SistScan

func makeTree(_ files: [String: String]) throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sist-scan-\(UUID().uuidString)").path
    for (path, text) in files {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }
    return root
}

final class TestBundleMarker {}

/// `swift test` builds sist-worker next to the test bundle. On macOS, Swift Testing loads that
/// bundle from a helper process, so WorkerLocator (which looks next to the main executable) cannot
/// see it: look next to the bundle, then in the package's own build directory.
func workerExecutable() -> URL? {
    if let found = WorkerLocator.find() {
        return found
    }
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("sist-worker"),
        packageRoot.appendingPathComponent(".build/debug/sist-worker"),
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

func setMtime(_ path: String, _ seconds: TimeInterval) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: path)
}

@Suite(.serialized) struct ScanCoordinatorTests {
    func run(_ isolation: ParserIsolation) async throws {
        let root = try makeTree([
            "a.txt": "first file about otters",
            "sub/b.html": "<title>Page</title><p>second file about 水獭</p>",
            "sub/c.json": #"{"note": "third file"}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let catalog = try Catalog(path: root + ".catalog/catalog.sqlite")
        defer { try? FileManager.default.removeItem(atPath: root + ".catalog") }

        var options = ScanOptions()
        options.threads = 2
        let source = try await catalog.addSource(root: root, options: options)
        let coordinator = ScanCoordinator(catalog: catalog, isolation: isolation)

        var counters = try await coordinator.scan(sourceId: source.id)
        #expect(counters.walked == 3)
        #expect(counters.parsed == 3)
        #expect(counters.errors == 0)
        #expect(try await catalog.search(SearchQuery(text: "水獭")).hits.map(\.document.name) == ["b.html"])
        #expect(try await catalog.search(SearchQuery(text: "page")).hits.first?.document.title == "Page")

        // Nothing changed
        counters = try await coordinator.scan(sourceId: source.id)
        #expect(counters.parsed == 0)
        #expect(counters.unchanged == 3)

        // One file changed, one deleted, one added
        try "first file about beavers".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try setMtime(root + "/a.txt", 1_000_000)
        try FileManager.default.removeItem(atPath: root + "/sub/c.json")
        try "fourth".write(toFile: root + "/d.txt", atomically: true, encoding: .utf8)
        counters = try await coordinator.scan(sourceId: source.id)
        #expect(counters.parsed == 2)
        #expect(counters.unchanged == 1)
        #expect(counters.deleted == 1)
        #expect(try await catalog.search(SearchQuery(text: "otters")).total == 0)
        #expect(try await catalog.search(SearchQuery(text: "beavers")).total == 1)
        #expect(try await catalog.search(SearchQuery()).total == 3)
    }

    @Test func inProcess() async throws {
        try await run(.inProcess)
    }

    @Test func subprocess() async throws {
        let worker = try #require(workerExecutable(), "sist-worker should be built next to the tests")
        try await run(.subprocess(worker))
    }

    @Test func crashedAndHungParsersOnlyCostTheirFile() async throws {
        let worker = try #require(workerExecutable())
        let root = try makeTree([
            "ok1.txt": "fine", "ok2.txt": "fine", "ok3.txt": "fine",
            "sist-test-crash.txt": "boom", "sist-test-hang.txt": "zzz",
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let catalog = try Catalog(path: root + ".catalog/catalog.sqlite")
        defer { try? FileManager.default.removeItem(atPath: root + ".catalog") }

        setenv("SIST_WORKER_TEST_CRASH_ON", "sist-test-crash.txt", 1)
        setenv("SIST_WORKER_TEST_HANG_ON", "sist-test-hang.txt", 1)
        defer {
            unsetenv("SIST_WORKER_TEST_CRASH_ON")
            unsetenv("SIST_WORKER_TEST_HANG_ON")
        }

        var options = ScanOptions()
        options.threads = 2
        options.jobTimeout = 2
        let source = try await catalog.addSource(root: root, options: options)
        let counters = try await ScanCoordinator(catalog: catalog, isolation: .subprocess(worker))
            .scan(sourceId: source.id)

        #expect(counters.parsed == 5)
        #expect(counters.errors == 2)
        #expect(try await catalog.search(SearchQuery(text: "fine")).total == 3)
        // Still findable by name
        let failed = try await catalog.search(SearchQuery(text: "sist-test"))
        #expect(failed.total == 2)
        for hit in failed.hits {
            let detail = try #require(try await catalog.document(id: hit.document.id))
            #expect(detail.error != nil)
        }
    }

    @Test func cancellationDeletesNothing() async throws {
        var files: [String: String] = [:]
        for i in 0..<600 { files["f\(i).txt"] = "file \(i)" }
        let root = try makeTree(files)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let catalog = try Catalog(path: root + ".catalog/catalog.sqlite")
        defer { try? FileManager.default.removeItem(atPath: root + ".catalog") }
        let source = try await catalog.addSource(root: root)
        let coordinator = ScanCoordinator(catalog: catalog, isolation: .inProcess)
        try await coordinator.scan(sourceId: source.id)

        // Every file changed: the rescan has to parse them all, and is cancelled during the first
        // batch, before the walk has seen most of them
        for i in 0..<600 {
            try setMtime(root + "/f\(i).txt", 1_000_000)
        }
        let cancel = CancelBox()
        let task = Task {
            try await coordinator.scan(sourceId: source.id, progress: { _ in cancel.cancel() })
        }
        cancel.set(task)
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        #expect(try await catalog.search(SearchQuery()).total == 600)
        #expect(try await catalog.sources().first?.lastScan?.status == .cancelled)
    }
}

final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ScanCounters, Error>?
    private var requested = false

    func set(_ task: Task<ScanCounters, Error>) {
        lock.lock()
        self.task = task
        let requested = self.requested
        lock.unlock()
        if requested { task.cancel() }
    }

    func cancel() {
        lock.lock()
        requested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

@Suite(.serialized) struct RebuildAndScopeTests {
    func setUp(_ files: [String: String]) async throws -> (Catalog, Source, String) {
        let root = try makeTree(files)
        let catalog = try Catalog(path: root + ".catalog/catalog.sqlite")
        let source = try await catalog.addSource(root: root)
        return (catalog, source, root)
    }

    func cleanUp(_ root: String) {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: root + ".catalog")
    }

    @Test func changingExtractionOptionsReparsesEverything() async throws {
        let (catalog, source, root) = try await setUp(["a.txt": "alpha beta gamma", "b.txt": "delta epsilon"])
        defer { cleanUp(root) }
        let coordinator = ScanCoordinator(catalog: catalog, isolation: .inProcess)
        try await coordinator.scan(sourceId: source.id)

        var options = source.options
        options.contentSizeLimit = 5
        try await catalog.updateSource(id: source.id, options: options)
        #expect(try await catalog.source(id: source.id).needsRebuild)

        var counters = try await coordinator.scan(sourceId: source.id)
        #expect(counters.parsed == 2)
        #expect(counters.unchanged == 0)
        #expect(try await catalog.search(SearchQuery(text: "gamma")).total == 0)
        #expect(try await catalog.search(SearchQuery(text: "alpha")).total == 1)

        counters = try await coordinator.scan(sourceId: source.id)
        #expect(counters.parsed == 0)

        // Options that only steer the walk do not reparse
        options.excludePattern = "/nothing-matches-this/"
        try await catalog.updateSource(id: source.id, options: options)
        counters = try await coordinator.scan(sourceId: source.id)
        #expect(counters.parsed == 0)
        #expect(counters.unchanged == 2)

        counters = try await coordinator.scan(sourceId: source.id, mode: .rebuild)
        #expect(counters.parsed == 2)
    }

    @Test func scopedScans() async throws {
        let (catalog, source, root) = try await setUp([
            "a/one.txt": "one", "a/sub/two.txt": "two", "b/three.txt": "three", "top.txt": "top",
        ])
        defer { cleanUp(root) }
        let coordinator = ScanCoordinator(catalog: catalog, isolation: .inProcess)
        try await coordinator.scan(sourceId: source.id)

        try "one changed".write(toFile: root + "/a/one.txt", atomically: true, encoding: .utf8)
        try setMtime(root + "/a/one.txt", 1_000_000)
        try "new".write(toFile: root + "/a/new.txt", atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: root + "/a/sub/two.txt")
        try FileManager.default.removeItem(atPath: root + "/b/three.txt")

        // Only the files directly in a/: the deletion in a/sub is not seen yet, nor the one in b/
        var counters = try await coordinator.scan(
            sourceId: source.id, scopes: [ScanScope(path: root + "/a", recursive: false)])
        #expect(counters.walked == 2)
        #expect(counters.parsed == 2)
        #expect(counters.deleted == 0)
        #expect(try await catalog.search(SearchQuery(text: "changed")).total == 1)
        #expect(try await catalog.search(SearchQuery()).total == 5)

        counters = try await coordinator.scan(sourceId: source.id, scopes: [ScanScope(path: root + "/a", recursive: true)])
        #expect(counters.deleted == 1)

        // A scope that no longer exists deletes what it held
        try FileManager.default.removeItem(atPath: root + "/b")
        counters = try await coordinator.scan(sourceId: source.id, scopes: [ScanScope(path: root + "/b", recursive: true)])
        #expect(counters.deleted == 1)
        #expect(Set(try await catalog.search(SearchQuery()).hits.map(\.document.name)) == ["one.txt", "new.txt", "top.txt"])
    }

    @Test func scopePlanning() async throws {
        let (catalog, source, root) = try await setUp(["a/x.txt": "x", ".hidden/y.txt": "y", "top.txt": "t"])
        defer { cleanUp(root) }

        #expect(ScanCoordinator.plan([ScanScope(path: "/elsewhere", recursive: true)], source: source) == [])
        #expect(ScanCoordinator.plan([ScanScope(path: root + "/", recursive: true)], source: source) == nil)
        #expect(ScanCoordinator.plan([
            ScanScope(path: root + "/a", recursive: true),
            ScanScope(path: root + "/a", recursive: false),
            ScanScope(path: root + "/a/deeper", recursive: false),
            ScanScope(path: root + "/a/deeper/", recursive: true),
            ScanScope(path: root + "/b", recursive: false),
        ], source: source) == [ScanScope(path: root + "/a", recursive: true), ScanScope(path: root + "/b", recursive: false)])

        let ignore = IgnoreList(root: root, patterns: ["ignored/"])
        #expect(ScanCoordinator.walkOptions(for: ScanScope(path: root + "/.hidden", recursive: true),
                                            source: source, ignoreList: ignore) == nil)
        #expect(ScanCoordinator.walkOptions(for: ScanScope(path: root + "/x/ignored/y", recursive: true),
                                            source: source, ignoreList: ignore) == nil)
        var limited = source
        limited.options.maxDepth = 1
        #expect(ScanCoordinator.walkOptions(for: ScanScope(path: root + "/a", recursive: true),
                                            source: limited, ignoreList: ignore)?.maxDepth == 0)
        #expect(ScanCoordinator.walkOptions(for: ScanScope(path: root + "/a/b", recursive: false),
                                            source: limited, ignoreList: ignore) == nil)

        // The first scan of a source covers all of it, whatever scopes it is given
        let counters = try await ScanCoordinator(catalog: catalog, isolation: .inProcess)
            .scan(sourceId: source.id, scopes: [ScanScope(path: root + "/a", recursive: false)])
        #expect(counters.walked == 2)
        #expect(try await catalog.source(id: source.id).indexedOptions != nil)
    }
}

@Suite struct ChangeScopesTests {
    @Test func filesRescanTheirFolderDirectoriesTheirSubtree() {
        let scopes = ChangeScopes.scopes(for: [
            FileChange(path: "/r/a/one.txt", isDirectory: false),
            FileChange(path: "/r/a/two.txt", isDirectory: false),
            FileChange(path: "/r/b", isDirectory: true),
            FileChange(path: "/r/c/d", isDirectory: false, mustRescanSubtree: true),
        ], root: "/r")
        #expect(scopes == [
            ScanScope(path: "/r/a", recursive: false),
            ScanScope(path: "/r/b", recursive: true),
            ScanScope(path: "/r/c/d", recursive: true),
        ])
    }

    @Test func lostTrackOfTheRootMeansAFullScan() {
        #expect(ChangeScopes.scopes(for: [FileChange(path: "/r", isDirectory: true, mustRescanSubtree: true)],
                                    root: "/r") == nil)
        // Dropped events are reported on "/"
        #expect(ChangeScopes.scopes(for: [FileChange(path: "/", isDirectory: false, mustRescanSubtree: true)],
                                    root: "/r") == nil)
        let many = (0..<10).map { FileChange(path: "/r/dir\($0)/file", isDirectory: false) }
        #expect(ChangeScopes.scopes(for: many, root: "/r", limit: 5) == nil)
        #expect(ChangeScopes.scopes(for: many, root: "/r", limit: 10)?.count == 10)
    }
}

@Suite struct ScanLockTests {
    @Test func oneHolderAtATime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sist-lock-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let catalogPath = directory + "/catalog.sqlite"

        let agent = ScanLock(catalogPath: catalogPath)
        let app = ScanLock(catalogPath: catalogPath)
        #expect(!ScanLock.isHeldElsewhere(catalogPath: catalogPath))
        #expect(agent.tryAcquire())
        #expect(agent.tryAcquire())
        #expect(!app.tryAcquire())
        #expect(ScanLock.isHeldElsewhere(catalogPath: catalogPath))
        agent.release()
        #expect(app.tryAcquire())
        #expect(app.isHeld)
        #expect(!agent.isHeld)
    }
}

@Suite(.serialized) struct ScanSchedulerTests {
    /// Scheduler events as a stream the test can wait on
    final class Events: @unchecked Sendable {
        let stream: AsyncStream<ScanScheduler.Event>
        let continuation: AsyncStream<ScanScheduler.Event>.Continuation

        init() {
            (stream, continuation) = AsyncStream.makeStream()
        }

        /// The progress reports up to the next finished scan, and its error
        func nextScan() async -> (progress: [ScanProgress], error: String?) {
            var progress: [ScanProgress] = []
            for await event in stream {
                switch event {
                case .progress(let report): progress.append(report)
                case .finished(_, let error): return (progress, error)
                }
            }
            return (progress, "stream ended")
        }
    }

    @Test func changesBecomeOneScopedScan() async throws {
        let root = try makeTree(["a/one.txt": "first", "b/two.txt": "second"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let catalog = try Catalog(path: root + ".catalog/catalog.sqlite")
        defer { try? FileManager.default.removeItem(atPath: root + ".catalog") }
        let source = try await catalog.addSource(root: root)
        let events = Events()
        let scheduler = ScanScheduler(catalog: catalog, isolation: .inProcess, rescanDelay: .milliseconds(200)) {
            events.continuation.yield($0)
        }

        await scheduler.scan(source.id)
        let first = await events.nextScan()
        #expect(first.error == nil)
        #expect(first.progress.last?.counters.parsed == 2)

        // Two bursts of changes in one folder: one scan of that folder, after things are quiet
        try "third about kingfishers".write(toFile: root + "/a/three.txt", atomically: true, encoding: .utf8)
        await scheduler.changed(source.id, [FileChange(path: root + "/a/three.txt", isDirectory: false)])
        await scheduler.changed(source.id, [FileChange(path: root + "/a/one.txt", isDirectory: false)])
        let rescan = await events.nextScan()
        #expect(rescan.progress.last?.scopes == [ScanScope(path: root + "/a", recursive: false)])
        #expect(rescan.progress.last?.counters.walked == 2)
        #expect(try await catalog.search(SearchQuery(text: "kingfishers")).total == 1)
        #expect(await scheduler.scanning.isEmpty)
    }

    @Test func requestsDuringAScanRunAfterItMerged() async throws {
        let root = try makeTree((0..<200).reduce(into: [:]) { $0["f\($1).txt"] = "file \($1)" })
        defer { try? FileManager.default.removeItem(atPath: root) }
        let catalog = try Catalog(path: root + ".catalog/catalog.sqlite")
        defer { try? FileManager.default.removeItem(atPath: root + ".catalog") }
        let source = try await catalog.addSource(root: root)
        let events = Events()
        let scheduler = ScanScheduler(catalog: catalog, isolation: .inProcess, rescanDelay: .milliseconds(100)) {
            events.continuation.yield($0)
        }

        await scheduler.scan(source.id)
        await scheduler.scan(source.id, scopes: [ScanScope(path: root, recursive: false)])
        await scheduler.scan(source.id, mode: .rebuild)
        #expect(await scheduler.scanning == [source.id])
        let first = await events.nextScan()
        #expect(first.progress.last?.isRebuild == false)
        // The two requests ran as one rebuild of the whole source
        let second = await events.nextScan()
        #expect(second.progress.last?.isRebuild == true)
        #expect(second.progress.last?.scopes == nil)
        #expect(second.progress.last?.counters.parsed == 200)
    }

    @Test func cancelling() async throws {
        let root = try makeTree((0..<300).reduce(into: [:]) { $0["f\($1).txt"] = "file \($1)" })
        defer { try? FileManager.default.removeItem(atPath: root) }
        let catalog = try Catalog(path: root + ".catalog/catalog.sqlite")
        defer { try? FileManager.default.removeItem(atPath: root + ".catalog") }
        let source = try await catalog.addSource(root: root)
        let events = Events()
        let scheduler = ScanScheduler(catalog: catalog, isolation: .inProcess) { events.continuation.yield($0) }

        await scheduler.scan(source.id)
        await scheduler.scan(source.id, mode: .rebuild)
        await scheduler.cancel(source.id)
        _ = await events.nextScan()
        // The queued rebuild was dropped with it
        try await Task.sleep(for: .milliseconds(200))
        #expect(await scheduler.scanning.isEmpty)
    }
}

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
        let worker = try #require(WorkerLocator.find(), "sist-worker should be built next to the tests")
        try await run(.subprocess(worker))
    }

    @Test func crashedAndHungParsersOnlyCostTheirFile() async throws {
        let worker = try #require(WorkerLocator.find())
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

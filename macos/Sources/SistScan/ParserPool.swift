import Foundation
import SistCore
import SistExtractors

/// The outcome of parsing one file: its documents (the file, then archive members) or an error.
public struct ParseJobResult: Sendable {
    public var entry: FileEntry
    public var results: [ParseResult]
    public var error: String?

    public init(entry: FileEntry, results: [ParseResult], error: String? = nil) {
        self.entry = entry
        self.results = results
        self.error = error
    }
}

/// Runs parse jobs, at most `capacity` at a time.
public protocol ParserPool: Sendable {
    var capacity: Int { get }
    func parse(_ entry: FileEntry) async -> ParseJobResult
    func shutdown() async
}

/// Parses on a dispatch queue inside the scanning process. No crash isolation and no way to stop
/// a parser that hangs; used when the `sist-worker` executable cannot be found, and in tests.
public final class InProcessParserPool: ParserPool {
    public let capacity: Int
    private let parser: DocumentParser
    // Not the Swift concurrency pool: extractors block on semaphores (see runBlocking)
    private let queue = DispatchQueue(label: "sist.parse", qos: .utility, attributes: .concurrent)

    public init(options: ScanOptions, log: LogHandler? = nil) {
        capacity = options.effectiveThreads
        parser = DocumentParser(options: options, log: log)
    }

    public func parse(_ entry: FileEntry) async -> ParseJobResult {
        await withCheckedContinuation { continuation in
            queue.async { [parser] in
                var results: [ParseResult] = []
                parser.parse(entry) { results.append($0) }
                continuation.resume(returning: ParseJobResult(entry: entry, results: results))
            }
        }
    }

    public func shutdown() async {}
}

public enum WorkerLocator {
    public static let executableName = "sist-worker"

    /// The `sist-worker` executable: `$SIST_WORKER_PATH`, inside the app bundle, or next to the
    /// running executable (the CLI, or `swift test`'s products directory).
    public static func find() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SIST_WORKER_PATH"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let url = Bundle.main.url(forAuxiliaryExecutable: executableName) {
            candidates.append(url)
        }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.resolvingSymlinksInPath().deletingLastPathComponent()
                .appendingPathComponent(executableName))
        }
        #if os(macOS)
        // Under `swift test` on macOS the test bundle is loaded by Xcode's xctest tool
        // (Bundle.allBundles crashes in swift-corelibs-foundation, where it is not needed)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(executableName))
        }
        #endif
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

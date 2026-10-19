import Foundation
import SistCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Parses in long-lived `sist-worker` processes, as sist2's scan master does: a parser that
/// crashes takes down its worker, not the scan, and a job that runs past `jobTimeout` gets its
/// worker killed. Either way the worker is replaced on the next job.
public final class SubprocessParserPool: ParserPool, @unchecked Sendable {
    public let capacity: Int
    private let executable: URL
    private let options: ScanOptions
    private let log: LogHandler?

    private let lock = NSLock()
    private var idle: [WorkerProcess] = []
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(executable: URL, options: ScanOptions, log: LogHandler? = nil) {
        self.executable = executable
        self.options = options
        self.log = log
        self.capacity = options.effectiveThreads
        // Writing to a worker that just died must fail with EPIPE, not kill the scan
        signal(SIGPIPE, SIG_IGN)
    }

    public func parse(_ entry: FileEntry) async -> ParseJobResult {
        await acquireSlot()
        defer { releaseSlot() }

        let worker: WorkerProcess
        do {
            worker = try takeIdleWorker() ?? WorkerProcess(executable: executable, options: options)
        } catch {
            return ParseJobResult(entry: entry, results: [], error: "Cannot start \(executable.path): \(error)")
        }

        let result = await worker.run(entry, timeout: options.jobTimeout, log: log)
        if worker.isAlive {
            returnIdleWorker(worker)
        }
        return result
    }

    public func shutdown() async {
        for worker in takeAllIdleWorkers() {
            worker.stop()
        }
    }

    // NSLock may not be used directly from async functions

    private func returnIdleWorker(_ worker: WorkerProcess) {
        lock.lock()
        idle.append(worker)
        lock.unlock()
    }

    private func takeAllIdleWorkers() -> [WorkerProcess] {
        lock.lock()
        defer { lock.unlock() }
        let workers = idle
        idle.removeAll()
        return workers
    }

    private func takeIdleWorker() throws -> WorkerProcess? {
        lock.lock()
        defer { lock.unlock() }
        return idle.popLast()
    }

    private func acquireSlot() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if running < capacity {
                running += 1
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func releaseSlot() {
        lock.lock()
        if waiters.isEmpty {
            running -= 1
            lock.unlock()
        } else {
            // The slot passes straight to the next waiter
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

/// One `sist-worker` process and its pipes.
final class WorkerProcess: @unchecked Sendable {
    private let process = Process()
    private let channel: FrameChannel
    // Held so the pipe ends stay open: a FileHandle closes its descriptor when it goes away
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var alive = true
    private var killedForTimeout = false

    // Frame reads block, so they run here rather than on the Swift concurrency pool
    private static let ioQueue = DispatchQueue(label: "sist.worker-io", attributes: .concurrent)

    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return alive
    }

    init(executable: URL, options: ScanOptions) throws {
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()

        channel = FrameChannel(readFD: output.fileHandleForReading.fileDescriptor,
                               writeFD: input.fileHandleForWriting.fileDescriptor)
        try channel.write(.configure, json: options)
    }

    func run(_ entry: FileEntry, timeout: TimeInterval, log: LogHandler?) async -> ParseJobResult {
        await withCheckedContinuation { continuation in
            Self.ioQueue.async {
                continuation.resume(returning: self.runBlocking(entry, timeout: timeout, log: log))
            }
        }
    }

    private func runBlocking(_ entry: FileEntry, timeout: TimeInterval, log: LogHandler?) -> ParseJobResult {
        let watchdog = DispatchWorkItem { [weak self] in
            self?.kill(forTimeout: true)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        let decoder = JSONDecoder()
        var results: [ParseResult] = []
        do {
            try channel.write(.job, json: entry)
            while true {
                guard let frame = try channel.read() else {
                    throw FrameError.truncated
                }
                switch frame.type {
                case .document:
                    results.append(ParseResult(document: try decoder.decode(ParsedDocument.self, from: frame.payload)))
                case .thumbnail:
                    if !results.isEmpty {
                        results[results.count - 1].thumbnails.append(frame.payload)
                    }
                case .log:
                    if let message = try? decoder.decode(LogMessage.self, from: frame.payload) {
                        log?(message)
                    }
                case .done:
                    let done = try decoder.decode(JobDone.self, from: frame.payload)
                    return ParseJobResult(entry: entry, results: results, error: done.error)
                default:
                    throw FrameError.unknownType(frame.type.rawValue)
                }
            }
        } catch {
            lock.lock()
            let timedOut = killedForTimeout
            lock.unlock()
            kill(forTimeout: false)
            let reason = timedOut
                ? "Parsing took longer than \(Int(timeout))s, worker killed"
                : "Worker died (\(error))"
            return ParseJobResult(entry: entry, results: results, error: reason)
        }
    }

    private func kill(forTimeout: Bool) {
        lock.lock()
        let wasAlive = alive
        alive = false
        if forTimeout && wasAlive {
            killedForTimeout = true
        }
        lock.unlock()
        if wasAlive && process.isRunning {
            #if canImport(Darwin)
            Darwin.kill(process.processIdentifier, SIGKILL)
            #else
            Glibc.kill(process.processIdentifier, SIGKILL)
            #endif
        }
    }

    /// Asks the worker to exit after its current job
    func stop() {
        try? channel.write(Frame(type: .bye))
        try? input.fileHandleForWriting.close()
        lock.lock()
        alive = false
        lock.unlock()
    }
}

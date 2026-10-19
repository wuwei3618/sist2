import Foundation

/// A value set from another thread before a semaphore is signalled.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// Runs async framework APIs (AVFoundation, QuickLook) from the synchronous extractors.
///
/// Parsers never run on the Swift concurrency pool (the worker parses on its main thread, the
/// in-process pool on its own dispatch queue), so blocking here cannot starve the task this waits for.
func runBlocking<T: Sendable>(timeout: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = LockedBox<Result<T, Error>?>(nil)
    let task = Task.detached {
        do {
            box.value = .success(try await operation())
        } catch {
            box.value = .failure(error)
        }
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        task.cancel()
        throw ExtractionError.timedOut
    }
    return try box.value!.get()
}

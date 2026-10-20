import CoreServices
import Foundation
import SistScan

/// FSEvents on a folder tree. sist2 relies on scheduled rescans; here the folders that changed
/// are rescanned incrementally (see ChangeScopes).
public final class FileSystemWatcher {
    private let path: String
    private let ignoredPrefixes: [String]
    private let onChange: ([FileChange]) -> Void
    private let queue = DispatchQueue(label: "sist.fsevents")
    private var stream: FSEventStreamRef?

    /// `onChange` runs on a background queue, at most every couple of seconds.
    public init(path: String, ignoring ignoredPrefixes: [String] = [], onChange: @escaping ([FileChange]) -> Void) {
        self.path = path
        self.ignoredPrefixes = ignoredPrefixes
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes: the paths are a CFArray of CFString
            let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray) as? [String] ?? []
            let flags = (0..<min(count, paths.count)).map { eventFlags[$0] }
            watcher.handle(paths, flags: flags)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let lostTrack = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)

    private func handle(_ paths: [String], flags: [FSEventStreamEventFlags]) {
        var events: [FileChange] = []
        for (path, flag) in zip(paths, flags) {
            let mustRescan = flag & Self.lostTrack != 0
            if !mustRescan && (ignoredPrefixes.contains { path.hasPrefix($0) } || path.contains("/.")) {
                continue
            }
            events.append(FileChange(
                path: path,
                isDirectory: flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0,
                mustRescanSubtree: mustRescan))
        }
        if !events.isEmpty {
            onChange(events)
        }
    }
}

import CoreServices
import Foundation

/// FSEvents on a folder tree. sist2 relies on scheduled rescans; here a change triggers an
/// incremental rescan, which is cheap since unchanged files are not parsed again.
final class FileSystemWatcher {
    private let path: String
    private let ignoredPrefixes: [String]
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "sist.fsevents")
    private var stream: FSEventStreamRef?

    /// `onChange` runs on a background queue, at most every couple of seconds.
    init(path: String, ignoring ignoredPrefixes: [String] = [], onChange: @escaping () -> Void) {
        self.path = path
        self.ignoredPrefixes = ignoredPrefixes
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes: the paths are a CFArray of CFString
            let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray) as? [String] ?? []
            watcher.handle(paths)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(_ paths: [String]) {
        let relevant = paths.contains { path in
            !ignoredPrefixes.contains { path.hasPrefix($0) } && !path.contains("/.")
        }
        if relevant {
            onChange()
        }
    }
}

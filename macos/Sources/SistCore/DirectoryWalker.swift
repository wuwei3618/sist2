import Foundation

#if canImport(Darwin)
import Darwin
private typealias DirHandle = UnsafeMutablePointer<DIR>
#else
import Glibc
private typealias DirHandle = OpaquePointer
#endif

public enum WalkError: Error, CustomStringConvertible {
    case cannotOpenRoot(String, Int32)

    public var description: String {
        switch self {
        case .cannotOpenRoot(let path, let code):
            return "Cannot open \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Pull-based depth-first walk of a source, the counterpart of sist2's walk.c.
///
/// The scan pulls entries in batches, so the walk can never run ahead of the parsers by more than
/// a batch: that is the backpressure sist2 gets from its bounded job queue. Symlinks are not
/// followed. Unreadable directories are reported and skipped.
public final class DirectoryWalker: Sequence, IteratorProtocol {
    private struct Frame {
        var handle: DirHandle
        var path: String
        var depth: Int
    }

    private let root: String
    private let options: ScanOptions
    private let ignoreList: IgnoreList
    private let exclude: NSRegularExpression?
    private let onError: ((String, String) -> Void)?
    private var stack: [Frame] = []

    public private(set) var directoriesVisited = 0
    /// Entries that could not be stat'ed and directories that could not be opened
    public private(set) var errorCount = 0

    public init(root: String, options: ScanOptions, ignoreList: IgnoreList? = nil,
                onError: ((_ path: String, _ message: String) -> Void)? = nil) throws {
        var root = root
        while root.count > 1 && root.hasSuffix("/") {
            root.removeLast()
        }
        self.root = root
        self.options = options
        self.ignoreList = ignoreList ?? IgnoreList.load(root: root)
        self.exclude = options.excludePattern.flatMap { try? NSRegularExpression(pattern: $0) }
        self.onError = onError

        guard let handle = opendir(root) else {
            throw WalkError.cannotOpenRoot(root, errno)
        }
        stack.append(Frame(handle: handle, path: root, depth: 0))
        directoriesVisited = 1
    }

    deinit {
        for frame in stack {
            closedir(frame.handle)
        }
    }

    public func next() -> FileEntry? {
        while let frame = stack.last {
            guard let entry = readdir(frame.handle) else {
                closedir(frame.handle)
                stack.removeLast()
                continue
            }

            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            if options.skipHiddenFiles && name.hasPrefix(".") { continue }

            let path = frame.path == "/" ? "/" + name : frame.path + "/" + name

            var info = stat()
            if lstat(path, &info) != 0 {
                reportError(path)
                continue
            }

            let type = info.st_mode & S_IFMT
            if type == S_IFDIR {
                if isPruned(path, depth: frame.depth + 1, isDirectory: true) { continue }
                if options.treatPackagesAsFiles && Self.isPackage(path: path, name: name) {
                    return FileEntry(path: path, mtime: Self.mtime(info), size: 0)
                }
                guard let handle = opendir(path) else {
                    reportError(path)
                    continue
                }
                directoriesVisited += 1
                stack.append(Frame(handle: handle, path: path, depth: frame.depth + 1))
            } else if type == S_IFREG {
                if isPruned(path, depth: frame.depth, isDirectory: false) { continue }
                return FileEntry(path: path, mtime: Self.mtime(info), size: Int64(info.st_size))
            }
        }
        return nil
    }

    private func reportError(_ path: String) {
        errorCount += 1
        onError?(path, String(cString: strerror(errno)))
    }

    /// Up to `size` entries; empty once the walk is over.
    public func next(batch size: Int) -> [FileEntry] {
        var batch: [FileEntry] = []
        batch.reserveCapacity(size)
        while batch.count < size, let entry = next() {
            batch.append(entry)
        }
        return batch
    }

    /// Depth counts the directories between the root and the entry: files in the root are at 0.
    private func isPruned(_ path: String, depth: Int, isDirectory: Bool) -> Bool {
        if options.maxDepth >= 0 && depth > options.maxDepth {
            return true
        }
        if let exclude, exclude.firstMatch(in: path, range: NSRange(path.startIndex..<path.endIndex, in: path)) != nil {
            return true
        }
        return ignoreList.isIgnored(path, isDirectory: isDirectory)
    }

    private static func mtime(_ info: stat) -> Int64 {
        #if canImport(Darwin)
        return Int64(info.st_mtimespec.tv_sec)
        #else
        return Int64(info.st_mtim.tv_sec)
        #endif
    }

    /// Bundles such as .app, .rtfd or .photoslibrary look like files in Finder
    private static func isPackage(path: String, name: String) -> Bool {
        #if os(macOS)
        guard name.contains(".") else { return false }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage ?? false
        #else
        return false
        #endif
    }
}

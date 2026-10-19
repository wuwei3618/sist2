import Foundation
import SistCore

/// The bytes being parsed: a file on disk, or an archive member held in memory.
public enum ExtractionInput: Sendable {
    case file(path: String)
    case data(Data, name: String)

    public var name: String {
        switch self {
        case .file(let path): return path.lastPathComponentFast
        case .data(_, let name): return name
        }
    }

    /// At most `limit` bytes from the start.
    public func read(limit: Int = .max) throws -> Data {
        switch self {
        case .data(let data, _):
            return limit >= data.count ? data : data.prefix(limit)
        case .file(let path):
            guard let handle = FileHandle(forReadingAtPath: path) else {
                throw ExtractionError.unreadable(path)
            }
            defer { try? handle.close() }
            if limit == .max {
                return try handle.readToEnd() ?? Data()
            }
            return try handle.read(upToCount: limit) ?? Data()
        }
    }

    /// Runs `body` with a file URL for the input, writing members to a temporary file first.
    /// Apple frameworks such as AVFoundation and QuickLook only take URLs.
    public func withFileURL<T>(_ body: (URL) throws -> T) throws -> T {
        switch self {
        case .file(let path):
            return try body(URL(fileURLWithPath: path))
        case .data(let data, let name):
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("sist-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent(name.isEmpty ? "member" : name)
            try data.write(to: url)
            return try body(url)
        }
    }
}

public enum ExtractionError: Error, CustomStringConvertible {
    case unreadable(String)
    case invalidFormat(String)
    case timedOut

    public var description: String {
        switch self {
        case .unreadable(let path): return "Cannot read \(path)"
        case .invalidFormat(let reason): return "Invalid file: \(reason)"
        case .timedOut: return "Timed out"
        }
    }
}

/// Collects document text up to the content size limit, like sist2's text_buffer. Runs of
/// whitespace collapse to a single space or newline; once full, appends are ignored so extractors
/// can check `isFull` and stop reading early.
public struct ContentBuffer: Sendable {
    public let limit: Int
    public private(set) var text = ""
    private var characterCount = 0

    public init(limit: Int) {
        self.limit = limit
    }

    public var isFull: Bool { characterCount >= limit }

    public mutating func append(_ string: String) {
        guard !isFull else { return }
        var pendingSpace: Character? = text.isEmpty ? nil : " "
        for character in string {
            if character.isWhitespace || character == "\u{0}" {
                if character.isNewline {
                    pendingSpace = "\n"
                } else if pendingSpace == nil {
                    pendingSpace = " "
                }
                continue
            }
            let separator = pendingSpace != nil && !text.isEmpty
            if characterCount + (separator ? 2 : 1) > limit {
                // No room left: the text never ends on a dangling separator
                characterCount = limit
                break
            }
            if separator, let space = pendingSpace {
                text.append(space)
                characterCount += 1
            }
            pendingSpace = nil
            text.append(character)
            characterCount += 1
        }
    }

    /// Starts a new paragraph.
    public mutating func appendLine(_ string: String) {
        append("\n" + string)
    }
}

/// What an extractor fills in.
public struct Extracted: Sendable {
    public var title: String?
    public var content: ContentBuffer
    public var metadata: [String: MetadataValue] = [:]
    /// JPEG data
    public var thumbnails: [Data] = []

    public init(contentLimit: Int) {
        content = ContentBuffer(limit: contentLimit)
    }

    public mutating func setMetadata(_ key: String, _ value: String?) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        metadata[key] = .string(value)
    }
}

/// Handed to an extractor along with its input.
public struct ExtractionContext {
    public let options: ScanOptions
    /// Path of the document being extracted
    public let path: String
    /// 0 for files on disk, +1 per enclosing archive
    public let depth: Int
    let logHandler: (LogLevel, String, String) -> Void
    let memberHandler: (ArchiveMember) -> Void

    public func log(_ level: LogLevel, _ message: String) {
        logHandler(level, path, message)
    }

    /// Hands an archive member to the parser, which indexes it as a document of its own.
    public func parseMember(_ member: ArchiveMember) {
        memberHandler(member)
    }
}

public struct ArchiveMember: Sendable {
    /// Path inside the archive, without a leading slash
    public var path: String
    /// nil when the member is over the size limit or could not be extracted: it is then indexed
    /// by name only
    public var data: Data?
    public var mtime: Int64
    public var size: Int64

    public init(path: String, data: Data?, mtime: Int64, size: Int64) {
        self.path = path
        self.data = data
        self.mtime = mtime
        self.size = size
    }
}

public protocol Extractor: Sendable {
    func accepts(mime: String, ext: String) -> Bool
    func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws
}

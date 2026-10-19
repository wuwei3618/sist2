import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Wire format between the scan and its `sist-worker` processes, after sist2's worker/protocol.h.
///
/// A frame is an 8 byte header (`UInt32` type, `UInt32` payload length, little endian) followed by
/// the payload. Structured payloads are JSON; thumbnails are raw JPEG so they are not base64'd.
///
///     scan -> worker   configure (ScanOptions), job (FileEntry), bye
///     worker -> scan   document (ParsedDocument), thumbnail (belongs to the last document),
///                      log (LogMessage), done (JobDone)
///
/// The scan sends one job at a time per worker and waits for `done`, so neither side can block
/// writing while the other blocks writing too.
public enum FrameType: UInt32, Sendable {
    case configure = 1
    case job = 2
    case bye = 3
    case document = 4
    case thumbnail = 5
    case log = 6
    case done = 7
}

public struct Frame: Sendable {
    public var type: FrameType
    public var payload: Data

    public init(type: FrameType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }
}

public struct JobDone: Codable, Sendable {
    public var error: String?

    public init(error: String? = nil) {
        self.error = error
    }
}

public enum LogLevel: Int, Codable, Sendable, Comparable {
    case debug, info, warning, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LogMessage: Codable, Sendable {
    public var level: LogLevel
    public var path: String
    public var message: String

    public init(level: LogLevel, path: String, message: String) {
        self.level = level
        self.path = path
        self.message = message
    }
}

public enum FrameError: Error, CustomStringConvertible {
    case io(Int32)
    case truncated
    case unknownType(UInt32)
    case payloadTooLarge(Int)

    public var description: String {
        switch self {
        case .io(let code): return "I/O error: \(String(cString: strerror(code)))"
        case .truncated: return "Stream ended in the middle of a frame"
        case .unknownType(let type): return "Unknown frame type \(type)"
        case .payloadTooLarge(let size): return "Frame payload of \(size) bytes is over the limit"
        }
    }
}

public enum FrameCodec {
    public static let headerSize = 8
    public static let maxPayload = 256 * 1024 * 1024

    public static func encode(_ frame: Frame) -> Data {
        var data = Data(capacity: headerSize + frame.payload.count)
        withUnsafeBytes(of: frame.type.rawValue.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(frame.payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(frame.payload)
        return data
    }

    public static func decodeHeader(_ header: Data) throws -> (FrameType, Int) {
        precondition(header.count == headerSize)
        let bytes = [UInt8](header)
        let rawType = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let length = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        guard let type = FrameType(rawValue: rawType) else { throw FrameError.unknownType(rawType) }
        guard Int(length) <= maxPayload else { throw FrameError.payloadTooLarge(Int(length)) }
        return (type, Int(length))
    }

    public static func json<T: Encodable>(_ type: FrameType, _ value: T) throws -> Frame {
        Frame(type: type, payload: try JSONEncoder().encode(value))
    }
}

/// Blocking frame IO on a file descriptor.
public final class FrameChannel: @unchecked Sendable {
    public let readFD: Int32
    public let writeFD: Int32
    private let writeLock = NSLock()

    public init(readFD: Int32, writeFD: Int32) {
        self.readFD = readFD
        self.writeFD = writeFD
    }

    /// nil on a clean end of stream (between frames).
    public func read() throws -> Frame? {
        guard let header = try readExactly(FrameCodec.headerSize, allowEOF: true) else { return nil }
        let (type, length) = try FrameCodec.decodeHeader(header)
        let payload = length > 0 ? try readExactly(length, allowEOF: false) ?? Data() : Data()
        return Frame(type: type, payload: payload)
    }

    public func write(_ frame: Frame) throws {
        guard frame.payload.count <= FrameCodec.maxPayload else {
            throw FrameError.payloadTooLarge(frame.payload.count)
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        try writeAll(FrameCodec.encode(frame))
    }

    public func write<T: Encodable>(_ type: FrameType, json value: T) throws {
        try write(try FrameCodec.json(type, value))
    }

    private func readExactly(_ count: Int, allowEOF: Bool) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                systemRead(readFD, raw.baseAddress! + offset, count - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw FrameError.io(errno)
            }
            if n == 0 {
                if offset == 0 && allowEOF { return nil }
                throw FrameError.truncated
            }
            offset += n
        }
        return Data(buffer)
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = systemWrite(writeFD, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw FrameError.io(errno)
                }
                offset += n
            }
        }
    }
}

private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.read(fd, buffer, count)
    #else
    return Glibc.read(fd, buffer, count)
    #endif
}

private func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(fd, buffer, count)
    #else
    return Glibc.write(fd, buffer, count)
    #endif
}

public typealias LogHandler = @Sendable (LogMessage) -> Void

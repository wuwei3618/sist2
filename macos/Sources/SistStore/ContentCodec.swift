import CSistZlib
import Foundation
import GRDB

/// How `content.text` holds a document's text. Long texts are stored zlib-compressed, as a BLOB:
/// the length of the UTF-8 text (4 bytes, little-endian), then the zlib stream. Short ones stay
/// TEXT. Chinese text takes about half the space, English about a third.
///
/// Compression is the slow part, so scans do it in their parallel tasks (`compress`) and the
/// writer only stores the result.
public enum ContentCodec {
    /// Shorter texts are not worth the trouble
    static let minimumLength = 512
    static let level: Int32 = 6

    /// The stored form of a long text, nil when the text is stored as is
    public static func compress(_ text: String) -> Data? {
        var text = text
        return text.withUTF8 { source -> Data? in
            guard source.count >= minimumLength, source.count <= Int(UInt32.max) else { return nil }
            var length = compressBound(UInt(source.count))
            var output = [UInt8](repeating: 0, count: 4 + Int(length))
            let status = output.withUnsafeMutableBufferPointer { buffer in
                compress2(buffer.baseAddress! + 4, &length, source.baseAddress, UInt(source.count), level)
            }
            guard status == SIST_Z_OK, 4 + Int(length) < source.count else { return nil }
            let count = UInt32(source.count)
            for byte in 0..<4 {
                output[byte] = UInt8(truncatingIfNeeded: count >> (8 * UInt32(byte)))
            }
            return Data(output[0..<(4 + Int(length))])
        }
    }

    /// What to store for `text`, given what `compress` returned for it if it was called already
    static func storedValue(_ text: String, compressed: Data?) -> DatabaseValue {
        (compressed ?? compress(text))?.databaseValue ?? text.databaseValue
    }

    /// The text of a stored value
    public static func decode(_ value: DatabaseValue) -> String? {
        switch value.storage {
        case .string(let text):
            return text
        case .blob(let data):
            return decompress(data)
        default:
            return nil
        }
    }

    static func decompress(_ data: Data) -> String? {
        guard data.count > 4 else { return nil }
        let count = data.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        var length = UInt(count)
        var output = [UInt8](repeating: 0, count: count)
        let status = output.withUnsafeMutableBufferPointer { buffer in
            data.withUnsafeBytes { raw in
                let source = raw.bindMemory(to: UInt8.self)
                return uncompress(buffer.baseAddress, &length, source.baseAddress! + 4, UInt(source.count - 4))
            }
        }
        guard status == SIST_Z_OK else { return nil }
        return String(decoding: output.prefix(Int(length)), as: UTF8.self)
    }
}

import Foundation
import SistCore

/// Kindle books: MOBI (Mobipocket), AZW, AZW3 (KF8), and the PalmDOC .prc/.pdb files they grew
/// out of, as sist2 indexes them with libmobi.
///
/// The file is a Palm database. Its first record holds the PalmDOC header, the MOBI header and
/// the EXTH metadata (author, publisher, subjects, cover); the next records hold the book as
/// HTML (XHTML for KF8), usually PalmDOC-compressed. A book with both a MOBI and a KF8 version
/// starts with the MOBI one, which is what is read. Books compressed with HUFF/CDIC, or
/// encrypted (DRM), keep their metadata only.
public struct MobiExtractor: Extractor {
    public init() {}

    static let mimes: Set<String> = ["application/x-mobipocket-ebook", "application/vnd.amazon.ebook"]

    public func accepts(mime: String, ext: String) -> Bool {
        Self.mimes.contains(mime)
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        let book = try MobiBook(bytes: [UInt8](input.read()))

        result.title = book.title
        result.setMetadata(MetaKey.author, book.exthStrings(100).joined(separator: ", "))
        result.setMetadata(MetaKey.publisher, book.exthStrings(101).first)
        result.setMetadata(MetaKey.keywords, book.exthStrings(105).joined(separator: "; "))
        result.setMetadata(MetaKey.language, book.exthStrings(524).first)
        if let description = book.exthStrings(103).first {
            result.content.appendLine(MarkupExtractor.strip(description).text)
        }

        if context.options.thumbnailCount > 0, let cover = book.coverImage,
           let thumbnail = ImageScaling.thumbnail(from: Data(cover), options: context.options) {
            result.thumbnails.append(thumbnail)
        }

        guard book.encryption == 0 else {
            throw ExtractionError.encrypted
        }
        // Markup takes several bytes per character of text
        let html = try book.text(limit: context.options.contentSizeLimit * 16 + 65536)
        result.content.appendLine(MarkupExtractor.strip(html).text)
    }
}

struct MobiBook {
    let database: PalmDatabase
    let compression: UInt16
    let textRecordCount: Int
    let encryption: UInt16
    /// Windows code page of the text: 1252 or 65001 (UTF-8)
    let codepage: Int
    let fullName: String?
    /// Which kinds of trailing entries text records end with
    let extraFlags: UInt16
    let firstImageRecord: Int?
    /// EXTH records by type, in file order
    let exth: [UInt32: [[UInt8]]]

    static let palmDocCompression: UInt16 = 2
    static let huffCDICCompression: UInt16 = 17480

    init(bytes: [UInt8]) throws {
        database = try PalmDatabase(bytes: bytes)
        guard let header = database.record(0), header.count >= 16 else {
            throw ExtractionError.invalidFormat("no PalmDOC header")
        }
        compression = header.be16(0)
        textRecordCount = Int(header.be16(8))
        encryption = header.be16(12)

        var codepage = 1252
        var fullName: String?
        var extraFlags: UInt16 = 0
        var firstImage: Int?
        var exth: [UInt32: [[UInt8]]] = [:]

        if header.count >= 0x84, header[16..<20].elementsEqual("MOBI".utf8) {
            let headerLength = Int(header.be32(20))
            codepage = Int(header.be32(28))
            let nameOffset = Int(header.be32(0x54))
            let nameLength = Int(header.be32(0x58))
            if nameLength > 0, nameOffset >= 0, nameOffset + nameLength <= header.count {
                fullName = TextDecoding.decode(Array(header[nameOffset..<(nameOffset + nameLength)]), codepage: codepage)
            }
            let image = header.be32(0x6C)
            if image != 0xFFFF_FFFF {
                firstImage = Int(image)
            }
            if headerLength >= 0xE4, header.count >= 0xF4 {
                extraFlags = header.be16(0xF2)
            }
            if header.be32(0x80) & 0x40 != 0 {
                exth = Self.parseEXTH(header, at: 16 + headerLength)
            }
        }
        self.codepage = codepage
        self.fullName = fullName
        self.extraFlags = extraFlags
        self.firstImageRecord = firstImage
        self.exth = exth
    }

    static func parseEXTH(_ header: [UInt8], at start: Int) -> [UInt32: [[UInt8]]] {
        guard start >= 0, start + 12 <= header.count, header[start..<(start + 4)].elementsEqual("EXTH".utf8) else {
            return [:]
        }
        var records: [UInt32: [[UInt8]]] = [:]
        var position = start + 12
        for _ in 0..<header.be32(start + 8) {
            guard position + 8 <= header.count else { break }
            let type = header.be32(position)
            let length = Int(header.be32(position + 4))
            guard length >= 8, position + length <= header.count else { break }
            records[type, default: []].append(Array(header[(position + 8)..<(position + length)]))
            position += length
        }
        return records
    }

    func exthStrings(_ type: UInt32) -> [String] {
        (exth[type] ?? []).map { TextDecoding.decode($0, codepage: codepage) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var title: String? {
        exthStrings(503).first ?? fullName ?? database.name
    }

    /// The cover image's record: EXTH 201 counts from the first image record
    var coverImage: [UInt8]? {
        guard let first = firstImageRecord, let offset = exth[201]?.first, offset.count == 4 else { return nil }
        let index = first + Int(offset.be32(0))
        guard let image = database.record(index), !image.isEmpty else { return nil }
        return image
    }

    /// The book's markup, at most `limit` bytes of it.
    func text(limit: Int) throws -> String {
        guard compression == 1 || compression == Self.palmDocCompression else {
            throw ExtractionError.invalidFormat(compression == Self.huffCDICCompression
                ? "HUFF/CDIC compression is not supported" : "unknown compression \(compression)")
        }
        var bytes: [UInt8] = []
        for index in stride(from: 1, through: textRecordCount, by: 1) {
            guard bytes.count < limit, let record = database.record(index) else { break }
            let content = record[..<(record.count - Self.trailingSize(of: record, flags: extraFlags))]
            if compression == Self.palmDocCompression {
                Self.decompressPalmDoc(content, into: &bytes)
            } else {
                bytes += content
            }
        }
        if bytes.count > limit {
            bytes.removeSubrange(limit...)
        }
        if codepage == 65001 {
            return TextDecoding.validUTF8Prefix(bytes) ?? String(decoding: bytes, as: UTF8.self)
        }
        return TextDecoding.decode(bytes, codepage: codepage)
    }

    /// Text records can end with entries for the reader (indexing data, the bytes of a character
    /// cut by the record boundary), described by the MOBI header's extra flags. Each flag above
    /// the lowest adds an entry whose size is a varint written backwards at the end; the lowest
    /// adds 1-4 bytes, their count in the last byte.
    static func trailingSize(of record: [UInt8], flags: UInt16) -> Int {
        var size = 0
        var remaining = flags >> 1
        while remaining != 0 {
            if remaining & 1 != 0 {
                var value = 0
                var shift = 0
                var position = record.count - size - 1
                while position >= 0 {
                    let byte = record[position]
                    value |= Int(byte & 0x7F) << shift
                    shift += 7
                    position -= 1
                    if byte & 0x80 != 0 || shift >= 28 {
                        break
                    }
                }
                size += value
            }
            remaining >>= 1
        }
        if flags & 1 != 0, record.count - size - 1 >= 0 {
            size += Int(record[record.count - size - 1] & 0x3) + 1
        }
        return min(max(size, 0), record.count)
    }

    /// PalmDOC's LZ77: literals, runs of up to 8 raw bytes, space + character pairs, and copies of
    /// 3-10 bytes from up to 2047 bytes back.
    static func decompressPalmDoc(_ input: ArraySlice<UInt8>, into output: inout [UInt8]) {
        var index = input.startIndex
        while index < input.endIndex {
            let byte = input[index]
            index += 1
            switch byte {
            case 0x00, 0x09...0x7F:
                output.append(byte)
            case 0x01...0x08:
                let end = min(index + Int(byte), input.endIndex)
                output += input[index..<end]
                index = end
            case 0xC0...0xFF:
                output.append(0x20)
                output.append(byte ^ 0x80)
            default:
                guard index < input.endIndex else { return }
                let pair = Int(byte) << 8 | Int(input[index])
                index += 1
                let distance = (pair >> 3) & 0x7FF
                let length = (pair & 0x7) + 3
                guard distance > 0, distance <= output.count else { continue }
                // The copy may overlap what it produces
                for _ in 0..<length {
                    output.append(output[output.count - distance])
                }
            }
        }
    }
}

/// The records of a Palm database (PDB): MOBI, AZW, PRC.
struct PalmDatabase {
    let bytes: [UInt8]
    /// Where each record starts, then the end of the file
    let offsets: [Int]
    /// The database name in the header, which PalmDOC books use as their title
    let name: String?

    init(bytes: [UInt8]) throws {
        guard bytes.count >= 78 else { throw ExtractionError.invalidFormat("not a Palm database") }
        let count = Int(bytes.be16(76))
        guard count > 0, 78 + count * 8 <= bytes.count else {
            throw ExtractionError.invalidFormat("bad Palm database record list")
        }
        var offsets = (0..<count).map { Int(bytes.be32(78 + 8 * $0)) }
        offsets.append(bytes.count)
        self.bytes = bytes
        self.offsets = offsets
        let nameBytes = bytes[0..<32].prefix { $0 != 0 }
        name = nameBytes.isEmpty ? nil : TextDecoding.decodeName(Array(nameBytes))
    }

    var count: Int { offsets.count - 1 }

    func record(_ index: Int) -> [UInt8]? {
        guard index >= 0, index < count else { return nil }
        let start = offsets[index]
        let end = offsets[index + 1]
        guard start <= end, end <= bytes.count else { return nil }
        return Array(bytes[start..<end])
    }
}

extension Array where Element == UInt8 {
    func be16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func be32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
}

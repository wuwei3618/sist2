import Foundation
import SistCore

/// Excel 97-2003 (.xls) and PowerPoint 97-2003 (.ppt). No Apple framework reads either, so the
/// container ([MS-CFB]) and the records holding text ([MS-XLS], [MS-PPT]) are parsed here.
public struct OLEOfficeExtractor: Extractor {
    public init() {}

    static let mimes: Set<String> = ["application/vnd.ms-excel", "application/vnd.ms-powerpoint",
                                     "application/x-ole-storage"]
    static let maxSize = 512 * 1024 * 1024

    public func accepts(mime: String, ext: String) -> Bool {
        Self.mimes.contains(mime)
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        let data = try input.read(limit: Self.maxSize + 1)
        guard data.count <= Self.maxSize else {
            throw ExtractionError.invalidFormat("larger than \(Self.maxSize / 1024 / 1024) MB")
        }
        let file = try CompoundFile([UInt8](data))
        if file.stream(named: OutlookMessage.propertiesStream) != nil {
            try OutlookExtractor.index(OutlookMessage(file: file).summary(), into: &result, context: context)
            return
        }

        // Readable even when the document is password protected
        if let summary = file.stream(named: "\u{05}SummaryInformation") {
            let properties = PropertySet.strings(summary)
            result.title = properties[PropertySet.title].flatMap { $0.isEmpty ? nil : $0 }
            result.setMetadata(MetaKey.author, properties[PropertySet.author])
            result.setMetadata(MetaKey.modifiedBy, properties[PropertySet.lastAuthor])
            for id in [PropertySet.subject, PropertySet.keywords, PropertySet.comments] {
                if let value = properties[id] {
                    result.content.appendLine(value)
                }
            }
        }

        if let workbook = file.stream(named: "Workbook") ?? file.stream(named: "Book") {
            try XLSText.extract(workbook, into: &result.content)
        } else if let slides = file.stream(named: "PowerPoint Document") {
            if file.stream(named: "EncryptedSummary") != nil {
                throw ExtractionError.encrypted
            }
            PPTText.extract(slides, into: &result.content)
        }
    }
}

// MARK: - Compound File Binary

/// Reads named streams of a Compound File Binary ("OLE2") file, the container of .xls, .ppt,
/// .doc and .msg. Every offset and chain is bounds-checked: a corrupt file yields missing or
/// short streams, never a crash or an endless loop.
struct CompoundFile {
    struct Entry {
        /// Position in the directory, for `children(of:)`
        var index: Int
        var name: String
        /// 1 storage, 2 stream, 5 root
        var type: UInt8
        var left: UInt32
        var right: UInt32
        var child: UInt32
        var start: UInt32
        var size: Int
    }

    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    static let endOfChain: UInt32 = 0xFFFF_FFFE
    static let noStream: UInt32 = 0xFFFF_FFFF

    private let bytes: [UInt8]
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniStreamCutoff: Int
    private let fat: [UInt32]
    private let miniFat: [UInt32]
    private let miniStream: [UInt8]
    let entries: [Entry]

    init(_ bytes: [UInt8]) throws {
        guard bytes.count >= 512, Array(bytes[0..<8]) == Self.signature else {
            throw ExtractionError.invalidFormat("not a compound file")
        }
        let sectorShift = Int(Bytes.u16(bytes, 0x1E))
        let miniSectorShift = Int(Bytes.u16(bytes, 0x20))
        guard sectorShift == 9 || sectorShift == 12, miniSectorShift > 0, miniSectorShift < sectorShift else {
            throw ExtractionError.invalidFormat("unsupported compound file sector size")
        }
        let majorVersion = Bytes.u16(bytes, 0x1A)
        let sectorSize = 1 << sectorShift
        self.bytes = bytes
        self.sectorSize = sectorSize
        self.miniSectorSize = 1 << miniSectorShift
        self.miniStreamCutoff = Int(Bytes.u32(bytes, 0x38))

        // The FAT is spread over sectors listed in the header (first 109) and in DIFAT sectors
        let fatSectorCount = Int(Bytes.u32(bytes, 0x2C))
        var fatSectors: [UInt32] = (0..<109).map { Bytes.u32(bytes, 0x4C + $0 * 4) }
        var difatSector = Bytes.u32(bytes, 0x44)
        var visited = Set<UInt32>()
        while difatSector < Self.endOfChain, visited.insert(difatSector).inserted,
              let sector = Self.sector(bytes, difatSector, size: sectorSize) {
            let perSector = sectorSize / 4 - 1
            fatSectors += (0..<perSector).map { Bytes.u32(sector, $0 * 4) }
            difatSector = Bytes.u32(sector, perSector * 4)
        }
        var fat: [UInt32] = []
        for location in fatSectors.prefix(fatSectorCount) where location < Self.endOfChain {
            guard let sector = Self.sector(bytes, location, size: sectorSize) else { continue }
            fat += (0..<(sectorSize / 4)).map { Bytes.u32(sector, $0 * 4) }
        }
        self.fat = fat

        let directory = Self.read(chain: Self.chain(from: Bytes.u32(bytes, 0x30), in: fat), of: bytes,
                                  sectorSize: sectorSize, size: nil)
        var entries: [Entry] = []
        for offset in stride(from: 0, to: directory.count - 127, by: 128) {
            let nameLength = min(Int(Bytes.u16(directory, offset + 0x40)), 64)
            let units = (0..<max(0, nameLength / 2 - 1)).map { Bytes.u16(directory, offset + $0 * 2) }
            var size = Int(truncatingIfNeeded: Bytes.u64(directory, offset + 0x78))
            if majorVersion == 3 {
                // Version 3 files may leave garbage in the high half
                size &= 0xFFFF_FFFF
            }
            entries.append(Entry(
                index: entries.count,
                name: String(decoding: units, as: UTF16.self),
                type: directory[offset + 0x42],
                left: Bytes.u32(directory, offset + 0x44),
                right: Bytes.u32(directory, offset + 0x48),
                child: Bytes.u32(directory, offset + 0x4C),
                start: Bytes.u32(directory, offset + 0x74),
                size: max(0, size)))
        }
        guard let root = entries.first, root.type == 5 else {
            throw ExtractionError.invalidFormat("compound file without root entry")
        }
        self.entries = entries

        // Streams under the cutoff live in the mini stream, the root entry's data, in 64 byte sectors
        miniStream = Self.read(chain: Self.chain(from: root.start, in: fat), of: bytes,
                               sectorSize: sectorSize, size: root.size)
        let miniFatBytes = Self.read(chain: Self.chain(from: Bytes.u32(bytes, 0x3C), in: fat), of: bytes,
                                     sectorSize: sectorSize, size: nil)
        miniFat = (0..<(miniFatBytes.count / 4)).map { Bytes.u32(miniFatBytes, $0 * 4) }
    }

    /// A stream directly under the root storage, or under `storage`. Names compare
    /// case-insensitively, as in [MS-CFB].
    func stream(named name: String, in storage: Int = 0) -> [UInt8]? {
        child(named: name, of: storage, type: 2).map(read)
    }

    func child(named name: String, of storage: Int, type: UInt8) -> Entry? {
        let wanted = name.uppercased()
        return children(of: storage).first { $0.type == type && $0.name.uppercased() == wanted }
    }

    /// The entries of a storage: its child and that child's siblings (a red-black tree)
    func children(of index: Int) -> [Entry] {
        var result: [Entry] = []
        var visited = Set<UInt32>()
        var pending = [entries[index].child]
        while let node = pending.popLast() {
            guard node != Self.noStream, Int(node) < entries.count, visited.insert(node).inserted else { continue }
            let entry = entries[Int(node)]
            result.append(entry)
            pending += [entry.left, entry.right]
        }
        return result
    }

    func read(_ entry: Entry) -> [UInt8] {
        if entry.size < miniStreamCutoff {
            var data: [UInt8] = []
            data.reserveCapacity(entry.size)
            for sector in Self.chain(from: entry.start, in: miniFat) {
                let start = Int(sector) * miniSectorSize
                guard start < miniStream.count else { break }
                data += miniStream[start..<min(start + miniSectorSize, miniStream.count)]
                if data.count >= entry.size { break }
            }
            return Array(data.prefix(entry.size))
        }
        return Self.read(chain: Self.chain(from: entry.start, in: fat), of: bytes, sectorSize: sectorSize,
                         size: entry.size)
    }

    /// Follows a FAT or mini FAT chain. Cycles and out-of-range links end it.
    static func chain(from start: UInt32, in table: [UInt32]) -> [UInt32] {
        var chain: [UInt32] = []
        var current = start
        while current < endOfChain, Int(current) < table.count, chain.count < table.count {
            chain.append(current)
            current = table[Int(current)]
        }
        return chain
    }

    static func sector(_ bytes: [UInt8], _ index: UInt32, size: Int) -> [UInt8]? {
        let start = (Int(index) + 1) * size
        guard index < endOfChain, start < bytes.count else { return nil }
        return Array(bytes[start..<min(start + size, bytes.count)])
    }

    static func read(chain: [UInt32], of bytes: [UInt8], sectorSize: Int, size: Int?) -> [UInt8] {
        var data: [UInt8] = []
        data.reserveCapacity(size ?? chain.count * sectorSize)
        for index in chain {
            let start = (Int(index) + 1) * sectorSize
            guard start < bytes.count else { break }
            data += bytes[start..<min(start + sectorSize, bytes.count)]
            if let size, data.count >= size { break }
        }
        if let size {
            return Array(data.prefix(size))
        }
        return data
    }
}

/// Little-endian reads that return 0 past the end instead of trapping.
enum Bytes {
    static func u8(_ bytes: [UInt8], _ offset: Int) -> UInt8 {
        offset >= 0 && offset < bytes.count ? bytes[offset] : 0
    }

    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(u8(bytes, offset)) | UInt16(u8(bytes, offset + 1)) << 8
    }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(u16(bytes, offset)) | UInt32(u16(bytes, offset + 2)) << 16
    }

    static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(u32(bytes, offset)) | UInt64(u32(bytes, offset + 4)) << 32
    }

    static func utf16(_ bytes: ArraySlice<UInt8>) -> String {
        let start = bytes.startIndex
        let units = (0..<(bytes.count / 2)).map { UInt16(bytes[start + $0 * 2]) | UInt16(bytes[start + $0 * 2 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
    }

    /// One byte per character, the "compressed" form of UTF-16 Office uses for Latin-1 text
    static func latin1(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.map { UInt16($0) }, as: UTF16.self)
    }
}

// MARK: - Property sets

/// The \u{05}SummaryInformation stream ([MS-OLEPS]): title, author and so on.
enum PropertySet {
    static let codepage: UInt32 = 1
    static let title: UInt32 = 2
    static let subject: UInt32 = 3
    static let author: UInt32 = 4
    static let keywords: UInt32 = 5
    static let comments: UInt32 = 6
    static let lastAuthor: UInt32 = 8

    /// The string properties of the first section, by property id.
    static func strings(_ stream: [UInt8]) -> [UInt32: String] {
        guard stream.count >= 48, Bytes.u16(stream, 0) == 0xFFFE else { return [:] }
        let section = Int(Bytes.u32(stream, 44))
        let count = min(Int(Bytes.u32(stream, section + 4)), 512)
        let properties: [(id: UInt32, offset: Int)] = (0..<count).map {
            (Bytes.u32(stream, section + 8 + $0 * 8), section + Int(Bytes.u32(stream, section + 12 + $0 * 8)))
        }

        var codepage = 1252
        if let entry = properties.first(where: { $0.id == Self.codepage }), Bytes.u16(stream, entry.offset) == 2 {
            // VT_I2, stored signed: UTF-8's 65001 reads as -535
            codepage = Int(Bytes.u16(stream, entry.offset + 4))
        }

        var strings: [UInt32: String] = [:]
        for (id, offset) in properties where offset + 8 <= stream.count {
            let length = Int(Bytes.u32(stream, offset + 4))
            let value: String
            switch Bytes.u16(stream, offset) {
            case 0x1E: // VT_LPSTR, in the code page, length in bytes including the terminator
                let end = min(offset + 8 + length, stream.count)
                value = TextDecoding.decode(Array(stream[(offset + 8)..<end]), codepage: codepage)
            case 0x1F: // VT_LPWSTR, length in characters including the terminator
                let end = min(offset + 8 + length * 2, stream.count)
                value = Bytes.utf16(stream[(offset + 8)..<end])
            default:
                continue
            }
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}").union(.whitespacesAndNewlines))
            if !trimmed.isEmpty {
                strings[id] = trimmed
            }
        }
        return strings
    }
}

// MARK: - Excel

/// Text of a BIFF8 workbook stream: sheet names and the shared string table, which holds the
/// text of every cell. Numbers and formulas are left out.
enum XLSText {
    static func extract(_ stream: [UInt8], into buffer: inout ContentBuffer) throws {
        var position = 0
        var checkedVersion = false
        while position + 4 <= stream.count, !buffer.isFull {
            let type = Bytes.u16(stream, position)
            let length = Int(Bytes.u16(stream, position + 2))
            let start = position + 4
            let end = min(start + length, stream.count)
            var next = start + length

            switch type {
            case 0x0809: // BOF
                if !checkedVersion {
                    checkedVersion = true
                    if Bytes.u16(stream, start) != 0x0600 {
                        throw ExtractionError.invalidFormat("Excel 5.0/95 workbooks are not supported")
                    }
                }
            case 0x002F: // FILEPASS
                throw ExtractionError.encrypted
            case 0x0085: // BOUNDSHEET8: position, state, type, then the sheet name
                buffer.appendLine(shortString(Array(stream[min(start, end)..<end]), at: 6))
            case 0x00FC: // SST, continued in the CONTINUE records that follow it
                var segments = [Array(stream[start..<end])]
                while next + 4 <= stream.count, Bytes.u16(stream, next) == 0x003C {
                    let continueLength = Int(Bytes.u16(stream, next + 2))
                    segments.append(Array(stream[(next + 4)..<min(next + 4 + continueLength, stream.count)]))
                    next += 4 + continueLength
                }
                sharedStrings(segments, into: &buffer)
            case 0x0204: // LABEL, cells written before shared strings existed
                buffer.appendLine(unicodeString(Array(stream[min(start, end)..<end]), at: 6))
            default:
                break
            }
            position = next
        }
    }

    static func sharedStrings(_ segments: [[UInt8]], into buffer: inout ContentBuffer) {
        var reader = SegmentReader(segments: segments)
        _ = reader.u32() // references
        let count = Int(reader.u32())
        for _ in 0..<count {
            guard !buffer.isFull, !reader.isAtEnd else { return }
            let characters = Int(reader.u16())
            let flags = reader.u8()
            let runs = flags & 0x08 != 0 ? Int(reader.u16()) : 0
            let extended = flags & 0x04 != 0 ? Int(reader.u32()) : 0
            buffer.appendLine(reader.characters(characters, twoBytes: flags & 0x01 != 0))
            reader.skip(runs * 4 + extended)
        }
    }

    /// ShortXLUnicodeString: 8 bit length, flags, characters
    static func shortString(_ bytes: [UInt8], at offset: Int) -> String {
        let count = Int(Bytes.u8(bytes, offset))
        return characters(bytes, at: offset + 2, count: count, twoBytes: Bytes.u8(bytes, offset + 1) & 1 != 0)
    }

    /// XLUnicodeString: 16 bit length, flags, characters
    static func unicodeString(_ bytes: [UInt8], at offset: Int) -> String {
        let count = Int(Bytes.u16(bytes, offset))
        return characters(bytes, at: offset + 3, count: count, twoBytes: Bytes.u8(bytes, offset + 2) & 1 != 0)
    }

    static func characters(_ bytes: [UInt8], at offset: Int, count: Int, twoBytes: Bool) -> String {
        let start = min(offset, bytes.count)
        let end = min(start + count * (twoBytes ? 2 : 1), bytes.count)
        return twoBytes ? Bytes.utf16(bytes[start..<end]) : Bytes.latin1(bytes[start..<end])
    }

    /// Reads across an SST record and its CONTINUE records. Structures continue byte for byte;
    /// characters cut by a record boundary resume after a new flags byte that says whether the
    /// rest is stored on one or two bytes.
    struct SegmentReader {
        let segments: [[UInt8]]
        var segment = 0
        var offset = 0

        var isAtEnd: Bool {
            var index = segment
            var position = offset
            while index < segments.count && position >= segments[index].count {
                index += 1
                position = 0
            }
            return index >= segments.count
        }

        mutating func u8() -> UInt8 {
            while segment < segments.count && offset >= segments[segment].count {
                segment += 1
                offset = 0
            }
            guard segment < segments.count else { return 0 }
            defer { offset += 1 }
            return segments[segment][offset]
        }

        mutating func u16() -> UInt16 {
            UInt16(u8()) | UInt16(u8()) << 8
        }

        mutating func u32() -> UInt32 {
            UInt32(u16()) | UInt32(u16()) << 16
        }

        mutating func skip(_ count: Int) {
            var remaining = count
            while remaining > 0, segment < segments.count {
                let available = segments[segment].count - offset
                if available <= 0 {
                    segment += 1
                    offset = 0
                    continue
                }
                let step = min(available, remaining)
                offset += step
                remaining -= step
            }
        }

        mutating func characters(_ count: Int, twoBytes: Bool) -> String {
            var units: [UInt16] = []
            units.reserveCapacity(count)
            var wide = twoBytes
            while units.count < count, segment < segments.count {
                let bytes = segments[segment]
                if offset >= bytes.count {
                    segment += 1
                    guard segment < segments.count, !segments[segment].isEmpty else { break }
                    wide = segments[segment][0] & 0x01 != 0
                    offset = 1
                    continue
                }
                if wide {
                    guard offset + 1 < bytes.count else {
                        offset = bytes.count
                        continue
                    }
                    units.append(UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
                    offset += 2
                } else {
                    units.append(UInt16(bytes[offset]))
                    offset += 1
                }
            }
            return String(decoding: units, as: UTF16.self)
        }
    }
}

// MARK: - PowerPoint

/// Text of a "PowerPoint Document" stream: the text atoms of slides, notes and text boxes.
/// Records are walked in stream order, stepping into containers; master slides and handouts
/// are skipped (their placeholder prompts are not content), repeated text is kept once.
enum PPTText {
    static let textChars: UInt16 = 0x0FA0
    static let textBytes: UInt16 = 0x0FA8
    static let mainMaster: UInt16 = 0x03F8
    static let handout: UInt16 = 0x0FC9
    static let slideListWithText: UInt16 = 0x0FF0

    static func extract(_ stream: [UInt8], into buffer: inout ContentBuffer) {
        var position = 0
        var seen = Set<String>()
        while position + 8 <= stream.count, !buffer.isFull {
            let versionAndInstance = Bytes.u16(stream, position)
            let type = Bytes.u16(stream, position + 2)
            let length = Int(Bytes.u32(stream, position + 4))
            let body = position + 8

            if versionAndInstance & 0x000F == 0x000F {
                // Container: step in, unless it only holds masters
                let isMasterList = type == slideListWithText && versionAndInstance >> 4 == 1
                position = type == mainMaster || type == handout || isMasterList ? body + length : body
                continue
            }

            let end = min(body + length, stream.count)
            var text: String?
            if type == textChars {
                text = Bytes.utf16(stream[body..<end])
            } else if type == textBytes {
                text = Bytes.latin1(stream[body..<end])
            }
            if let text {
                // Field placeholders such as the slide number ("*") carry no words
                let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if SearchText.containsTokenCharacter(key) && seen.insert(key).inserted {
                    buffer.appendLine(text)
                }
            }
            position = body + length
        }
    }
}

import Foundation
import SistCore

/// Outlook's own formats: single messages (.msg, [MS-OXMSG]) and data files (.pst and .ost,
/// [MS-PST]). Both hold MAPI properties; neither is readable by a system framework.
///
/// A .msg is indexed like an .eml. A data file is a mailbox: its messages become members named
/// `folder/00001 subject.eml`, turned into MIME so that their attachments are found and opened
/// the same way as those of any other message.
public struct OutlookExtractor: Extractor {
    public init() {}

    static let messageMime = "application/vnd.ms-outlook"
    static let dataFileMime = "application/vnd.ms-outlook-pst"

    public func accepts(mime: String, ext: String) -> Bool {
        mime == Self.messageMime || mime == Self.dataFileMime
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        if try [UInt8](input.read(limit: 4)).elementsEqual("!BDN".utf8) {
            try extractDataFile(input, into: &result, context: context)
            return
        }
        let data = try input.read(limit: OLEOfficeExtractor.maxSize + 1)
        guard data.count <= OLEOfficeExtractor.maxSize else {
            throw ExtractionError.invalidFormat("larger than \(OLEOfficeExtractor.maxSize / 1024 / 1024) MB")
        }
        let message = try OutlookMessage(file: CompoundFile([UInt8](data)))
        Self.index(message.summary(), into: &result, context: context)
    }

    static func index(_ summary: MessageSummary, into result: inout Extracted, context: ExtractionContext) {
        summary.index(into: &result, context: context)
    }

    func extractDataFile(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        let file = try PSTFile(input)
        result.title = file.storeName
        let emitMembers = MailExtractor.emitsMembers(context)
        var count = 0
        try file.forEachMessage { message in
            count += 1
            let summary = message.summary
            result.content.appendLine(summary.subject ?? "")
            guard emitMembers else { return }
            let bytes = summary.rfc822()
            let tooLarge = Int64(bytes.count) > context.options.maxArchiveMemberSize
            context.parseMember(ArchiveMember(path: message.name, data: tooLarge ? nil : Data(bytes),
                                              mtime: summary.date.map { Int64($0.timeIntervalSince1970) } ?? 0,
                                              size: Int64(bytes.count)))
        }
        result.metadata[MetaKey.archiveMembers] = .int(Int64(count))
    }

    /// An attachment of a .msg, or a message of a data file, by its member name
    public static func member(_ name: String, in input: ExtractionInput, limit: Int64) throws -> Data {
        if try [UInt8](input.read(limit: 4)).elementsEqual("!BDN".utf8) {
            var found: [UInt8]?
            try PSTFile(input).forEachMessage(named: name) { found = $0.summary.rfc822() }
            if let found {
                return Data(found)
            }
        } else {
            let data = try input.read(limit: OLEOfficeExtractor.maxSize + 1)
            let summary = try OutlookMessage(file: CompoundFile([UInt8](data))).summary()
            if let attachment = summary.namedAttachments.first(where: { $0.name == name }) {
                return Data(attachment.data)
            }
        }
        throw ExtractionError.invalidFormat("\(name) not found")
    }

    static func isOutlook(_ input: ExtractionInput) -> Bool {
        let ext = input.name.pathExtensionFast.lowercased()
        if ["msg", "pst", "ost"].contains(ext) {
            return true
        }
        return (try? [UInt8](input.read(limit: 4)).elementsEqual("!BDN".utf8)) ?? false
    }
}

// MARK: - MAPI properties

enum MAPI {
    // Property types
    static let int16: UInt16 = 0x0002
    static let int32: UInt16 = 0x0003
    static let boolean: UInt16 = 0x000B
    static let object: UInt16 = 0x000D
    static let int64: UInt16 = 0x0014
    static let string8: UInt16 = 0x001E
    static let string: UInt16 = 0x001F
    static let time: UInt16 = 0x0040
    static let binary: UInt16 = 0x0102

    // Property ids
    static let subject: UInt16 = 0x0037
    static let senderName: UInt16 = 0x0C1A
    static let senderEmail: UInt16 = 0x0C1F
    static let sentRepresentingName: UInt16 = 0x0042
    static let displayTo: UInt16 = 0x0E04
    static let displayCc: UInt16 = 0x0E03
    static let clientSubmitTime: UInt16 = 0x0039
    static let deliveryTime: UInt16 = 0x0E06
    static let body: UInt16 = 0x1000
    static let bodyHTML: UInt16 = 0x1013
    static let rtfCompressed: UInt16 = 0x1009
    static let internetCodepage: UInt16 = 0x3FDE
    static let messageCodepage: UInt16 = 0x3FFD
    static let displayName: UInt16 = 0x3001
    static let attachData: UInt16 = 0x3701
    static let attachFilename: UInt16 = 0x3704
    static let attachMethod: UInt16 = 0x3705
    static let attachLongFilename: UInt16 = 0x3707

    static let attachEmbeddedMessage: Int32 = 5

    /// 100 ns intervals since 1601
    static func date(fromFileTime value: UInt64) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 10_000_000 - 11_644_473_600)
    }

    /// A subject may start with U+0001 and the length of its prefix ("RE: "), which is part of it
    static func cleanSubject(_ subject: String) -> String {
        var scalars = subject.unicodeScalars[...]
        if scalars.first == "\u{01}" {
            scalars = scalars.dropFirst(2)
        }
        return String(scalars)
    }
}

/// The properties of one object (message, attachment) as stored: by id, with their type and bytes.
struct MAPIProperties {
    var values: [UInt16: (type: UInt16, bytes: [UInt8])] = [:]
    /// Of 8-bit strings, when the object says. Folder names in ANSI files never do: they are in
    /// the code page of the Windows that wrote them, guessed as UTF-8 or else GB18030.
    var codepage: Int?

    func string(_ id: UInt16) -> String? {
        guard let value = values[id] else { return nil }
        var bytes = value.bytes[...]
        switch value.type {
        case MAPI.string:
            if bytes.count >= 2, bytes.suffix(2).allSatisfy({ $0 == 0 }) {
                bytes = bytes.dropLast(2)
            }
            return Bytes.utf16(bytes)
        case MAPI.string8:
            while bytes.last == 0 {
                bytes = bytes.dropLast()
            }
            return codepage.map { TextDecoding.decode(Array(bytes), codepage: $0) } ?? TextDecoding.decodeName(Array(bytes))
        default:
            return nil
        }
    }

    func binary(_ id: UInt16) -> [UInt8]? {
        guard let value = values[id], value.type == MAPI.binary || value.type == MAPI.object else { return nil }
        return value.bytes
    }

    func int32(_ id: UInt16) -> Int32? {
        guard let value = values[id], value.type == MAPI.int32 || value.type == MAPI.boolean, value.bytes.count >= 4 else {
            return nil
        }
        return Int32(bitPattern: Bytes.u32(value.bytes, 0))
    }

    func date(_ id: UInt16) -> Date? {
        guard let value = values[id], value.type == MAPI.time, value.bytes.count >= 8 else { return nil }
        return MAPI.date(fromFileTime: Bytes.u64(value.bytes, 0))
    }

    /// The common fields of a message; attachments are added by the caller
    func messageSummary() -> MessageSummary {
        var summary = MessageSummary()
        summary.subject = string(MAPI.subject).map(MAPI.cleanSubject)
        let name = string(MAPI.senderName) ?? string(MAPI.sentRepresentingName)
        let email = string(MAPI.senderEmail).flatMap { $0.contains("@") ? $0 : nil }
        switch (name, email) {
        case let (name?, email?) where name != email: summary.from = "\(name) <\(email)>"
        case let (name?, _): summary.from = name
        case let (nil, email?): summary.from = email
        default: break
        }
        summary.to = string(MAPI.displayTo)
        summary.cc = string(MAPI.displayCc)
        summary.date = date(MAPI.deliveryTime) ?? date(MAPI.clientSubmitTime)
        if let body = string(MAPI.body), !body.isEmpty {
            summary.texts = [body]
        } else if let html = string(MAPI.bodyHTML) ?? binary(MAPI.bodyHTML).map({ TextDecoding.decode(Data($0)) }) {
            summary.texts = [MarkupExtractor.strip(html).text]
        } else if let rtf = binary(MAPI.rtfCompressed).flatMap(CompressedRTF.decompress) {
            summary.texts = [RTFText.plainText(rtf)]
        }
        return summary
    }

    /// The name an attachment is listed under
    func attachmentName(number: Int) -> String {
        for id in [MAPI.attachLongFilename, MAPI.attachFilename, MAPI.displayName] {
            if let name = string(id), !name.isEmpty {
                return (name as NSString).lastPathComponent
            }
        }
        return "attachment-\(number)"
    }
}

// MARK: - .msg

/// A .msg file: a compound file whose `__substg1.0_IIIITTTT` streams hold variable-size
/// properties and whose `__properties_version1.0` streams hold the fixed-size ones. Recipients
/// and attachments are storages; an attached message is a storage holding a message.
struct OutlookMessage {
    static let propertiesStream = "__properties_version1.0"

    let file: CompoundFile

    init(file: CompoundFile) throws {
        guard file.stream(named: Self.propertiesStream) != nil else {
            throw ExtractionError.invalidFormat("not an Outlook message")
        }
        self.file = file
    }

    func summary() -> MessageSummary {
        summary(storage: 0, headerSize: 32, depth: 0)
    }

    private func summary(storage: Int, headerSize: Int, depth: Int) -> MessageSummary {
        let properties = properties(of: storage, headerSize: headerSize)
        var summary = properties.messageSummary()
        guard depth < MailBody.maxDepth else { return summary }
        let attachments = file.children(of: storage)
            .filter { $0.type == 1 && $0.name.hasPrefix("__attach_version1.0_#") }
            .sorted { $0.name < $1.name }
        for (number, entry) in attachments.enumerated() {
            let attachment = self.properties(of: entry.index, headerSize: 8)
            let name = attachment.attachmentName(number: number + 1)
            if let embedded = file.child(named: "__substg1.0_3701000D", of: entry.index, type: 1) {
                let message = self.summary(storage: embedded.index, headerSize: 24, depth: depth + 1)
                let base = name.lowercased().hasSuffix(".msg") ? (name as NSString).deletingPathExtension : name
                summary.attachments.append((base + ".eml", message.rfc822()))
            } else {
                summary.attachments.append((name, attachment.binary(MAPI.attachData) ?? []))
            }
        }
        return summary
    }

    func properties(of storage: Int, headerSize: Int) -> MAPIProperties {
        var properties = MAPIProperties()
        for entry in file.children(of: storage) where entry.type == 2 && entry.name.hasPrefix("__substg1.0_") {
            let tag = entry.name.dropFirst("__substg1.0_".count)
            guard tag.count == 8, let value = UInt32(tag, radix: 16) else { continue }
            properties.values[UInt16(value >> 16)] = (UInt16(value & 0xFFFF), file.read(entry))
        }
        // Fixed-size values: 16-byte entries of tag, flags and an 8-byte value
        if let stream = file.stream(named: Self.propertiesStream, in: storage) {
            var offset = headerSize
            while offset + 16 <= stream.count {
                let tag = Bytes.u32(stream, offset)
                let type = UInt16(tag & 0xFFFF)
                if [MAPI.int16, MAPI.int32, MAPI.boolean, MAPI.int64, MAPI.time].contains(type) {
                    properties.values[UInt16(tag >> 16)] = (type, Array(stream[(offset + 8)..<(offset + 16)]))
                }
                offset += 16
            }
        }
        if let codepage = properties.int32(MAPI.internetCodepage) ?? properties.int32(MAPI.messageCodepage) {
            properties.codepage = Int(codepage)
        }
        return properties
    }
}

// MARK: - Compressed RTF

/// [MS-OXRTFCP]: the LZ77 variant Outlook stores RTF bodies in ("LZFu"), or uncompressed ("MELA").
enum CompressedRTF {
    static let dictionary = Array(("{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}{\\f0\\fnil \\froman \\fswiss "
        + "\\fmodern \\fscript \\fdecor MS Sans SerifSymbolArialTimes New RomanCourier{\\colortbl\\red0\\green0"
        + "\\blue0\r\n\\par \\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx").utf8)

    static func decompress(_ data: [UInt8]) -> [UInt8]? {
        guard data.count >= 16 else { return nil }
        let rawSize = Int(Bytes.u32(data, 4))
        let type = Bytes.u32(data, 8)
        if type == 0x414C_454D {  // "MELA"
            return Array(data[16..<min(data.count, 16 + rawSize)])
        }
        guard type == 0x7546_5A4C else { return nil }  // "LZFu"

        var window = [UInt8](repeating: 0, count: 4096)
        window.replaceSubrange(0..<dictionary.count, with: dictionary)
        var position = dictionary.count
        var out: [UInt8] = []
        out.reserveCapacity(rawSize)
        var index = 16
        while index < data.count {
            let control = data[index]
            index += 1
            for bit in 0..<8 {
                guard index < data.count else { return out }
                if control & (1 << bit) == 0 {
                    let byte = data[index]
                    index += 1
                    out.append(byte)
                    window[position] = byte
                    position = (position + 1) & 0xFFF
                } else {
                    guard index + 1 < data.count else { return out }
                    let reference = Int(data[index]) << 8 | Int(data[index + 1])
                    index += 2
                    let offset = reference >> 4
                    let length = (reference & 0xF) + 2
                    // A reference to the write position ends the stream
                    if offset == position {
                        return out
                    }
                    for step in 0..<length {
                        let byte = window[(offset + step) & 0xFFF]
                        out.append(byte)
                        window[position] = byte
                        position = (position + 1) & 0xFFF
                    }
                }
            }
        }
        return out
    }
}

/// The text of an RTF document: groups that are not text (font and colour tables, pictures,
/// `\*` destinations) are skipped, `\'hh` bytes decoded in the document's code page, `\uN`
/// characters taken with their fallback skipped.
enum RTFText {
    static let skippedDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "header", "footer", "headerl", "headerr",
        "footerl", "footerr", "themedata", "colorschememapping", "latentstyles", "datastore", "xmlnstbl",
        "listtable", "listoverridetable", "rsidtbl", "generator", "filetbl", "revtbl", "fldinst", "mmathPr",
    ]

    static func plainText(_ rtf: [UInt8]) -> String {
        var out = ""
        var pending: [UInt8] = []
        var codepage = 1252
        // Per group: skipping, and how many fallback characters follow \u
        var stack: [(skip: Bool, unicodeSkip: Int)] = [(false, 1)]
        var skipFallback = 0
        var index = 0

        func flush() {
            if !pending.isEmpty {
                out += TextDecoding.decode(pending, codepage: codepage)
                pending.removeAll()
            }
        }
        func emit(_ byte: UInt8) {
            guard !stack[stack.count - 1].skip else { return }
            if skipFallback > 0 {
                skipFallback -= 1
                return
            }
            pending.append(byte)
        }
        func emit(_ text: String) {
            guard !stack[stack.count - 1].skip else { return }
            flush()
            out += text
        }

        while index < rtf.count {
            let byte = rtf[index]
            index += 1
            switch byte {
            case 0x7B:  // {
                stack.append(stack[stack.count - 1])
                // A group starting with \* is a destination readers may ignore
                if index + 1 < rtf.count, rtf[index] == 0x5C, rtf[index + 1] == 0x2A {
                    stack[stack.count - 1].skip = true
                }
            case 0x7D:  // }
                if stack.count > 1 {
                    stack.removeLast()
                }
            case 0x5C:  // \
                guard index < rtf.count else { break }
                let next = rtf[index]
                if next == 0x27, index + 2 < rtf.count,  // \'hh
                   let high = QuotedPrintable.hexValue(rtf[index + 1]), let low = QuotedPrintable.hexValue(rtf[index + 2]) {
                    index += 3
                    emit(high << 4 | low)
                } else if (0x61...0x7A).contains(next) || (0x41...0x5A).contains(next) {
                    var end = index
                    while end < rtf.count, (0x61...0x7A).contains(rtf[end]) || (0x41...0x5A).contains(rtf[end]) {
                        end += 1
                    }
                    let word = String(decoding: rtf[index..<end], as: UTF8.self)
                    var numberEnd = end
                    if numberEnd < rtf.count, rtf[numberEnd] == 0x2D {
                        numberEnd += 1
                    }
                    while numberEnd < rtf.count, (0x30...0x39).contains(rtf[numberEnd]) {
                        numberEnd += 1
                    }
                    let parameter = Int(String(decoding: rtf[end..<numberEnd], as: UTF8.self))
                    index = numberEnd
                    if index < rtf.count, rtf[index] == 0x20 {
                        index += 1
                    }
                    switch word {
                    case "par", "line", "row", "sect", "page":
                        emit("\n")
                    case "tab", "cell":
                        emit("\t")
                    case "ansicpg":
                        flush()
                        codepage = parameter ?? codepage
                    case "uc":
                        stack[stack.count - 1].unicodeSkip = parameter ?? 1
                    case "u":
                        if var value = parameter {
                            if value < 0 {
                                value += 65536
                            }
                            emit(String(Character(Unicode.Scalar(UInt32(clamping: value)) ?? "\u{FFFD}")))
                            skipFallback = stack[stack.count - 1].unicodeSkip
                        }
                    case "bin":
                        index += min(max(0, parameter ?? 0), rtf.count - index)
                    default:
                        if skippedDestinations.contains(word) {
                            stack[stack.count - 1].skip = true
                        }
                    }
                } else {
                    // Control symbols: escaped braces and backslash, non-breaking space...
                    index += 1
                    switch next {
                    case 0x5C, 0x7B, 0x7D: emit(next)
                    case 0x7E: emit(" ")
                    default: break
                    }
                }
            case 0x0D, 0x0A:
                break
            default:
                emit(byte)
            }
        }
        flush()
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

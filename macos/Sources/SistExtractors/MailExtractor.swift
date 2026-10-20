import Foundation
import SistCore

/// Mail: single messages (.eml, Apple Mail's .emlx) and mailboxes (.mbox).
///
/// A message's text is its main header fields, then its text/plain body (or its HTML body,
/// stripped, when there is no plain one). Attachments and forwarded messages become members, as
/// the files of an archive do, and so do the messages of a mailbox. The archive mode applies:
/// with `skip` or `list`, attachments and messages are only listed.
public struct MailExtractor: Extractor {
    public init() {}

    public func accepts(mime: String, ext: String) -> Bool {
        mime == "message/rfc822" || mime == "application/mbox"
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        let head = try [UInt8](input.read(limit: 5))
        if head.elementsEqual("From ".utf8) {
            try extractMailbox(input, into: &result, context: context)
            return
        }
        let limit = Int(min(context.options.maxArchiveMemberSize, Int64(Int.max / 2)))
        let data = try input.read(limit: limit + 1)
        guard data.count <= limit else {
            throw ExtractionError.invalidFormat("message larger than the member size limit")
        }
        let message = MIMEPart(Self.unwrapEMLX([UInt8](data))[...])
        Self.index(message, into: &result, context: context)
    }

    static func emitsMembers(_ context: ExtractionContext) -> Bool {
        (context.options.archiveMode == .shallow || context.options.archiveMode == .recurse)
            && context.depth < DocumentParser.maxArchiveDepth
    }

    /// An .emlx file is the message's length on a line, the message, then an Apple plist.
    static func unwrapEMLX(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        guard let newline = bytes.prefix(24).firstIndex(of: 0x0A) else { return bytes[...] }
        let digits = String(decoding: bytes[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(digits) else { return bytes[...] }
        let start = newline + 1
        return bytes[start..<min(bytes.count, start + length)]
    }

    static func index(_ message: MIMEPart, into result: inout Extracted, context: ExtractionContext) {
        MessageSummary(message).index(into: &result, context: context)
    }

    static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var number = 2
        while !used.insert(candidate).inserted {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            number += 1
        }
        return candidate
    }

    /// A file name made of a subject: no slashes, not too long
    static func fileName(_ text: String, fallback: String) -> String {
        let cleaned = text.map { "/\\:\0\n\r\t".contains($0) ? "_" : $0 }
        let name = String(String(cleaned).trimmingCharacters(in: .whitespaces).prefix(80))
        return name.isEmpty ? fallback : name
    }

    // MARK: Mailboxes

    func extractMailbox(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        let emitMembers = Self.emitsMembers(context)
        var messages = try MailboxMessages(input, limit: Int(min(context.options.maxArchiveMemberSize, Int64(Int.max / 2))))
        var count = 0
        while let message = messages.next() {
            count += 1
            result.content.appendLine(message.subject)
            guard emitMembers else { continue }
            context.parseMember(ArchiveMember(
                path: message.name, data: message.isComplete ? Data(message.bytes) : nil,
                mtime: message.date.map { Int64($0.timeIntervalSince1970) } ?? 0, size: Int64(message.size)))
        }
        result.metadata[MetaKey.archiveMembers] = .int(Int64(count))
    }

    // MARK: Members

    /// The bytes of an attachment of a message, or of a message of a mailbox, by the name it was
    /// indexed under, for opening it from the app.
    public static func member(_ name: String, in input: ExtractionInput, limit: Int64) throws -> Data {
        let intLimit = Int(min(limit, Int64(Int.max / 2)))
        if try [UInt8](input.read(limit: 5)).elementsEqual("From ".utf8) {
            var messages = try MailboxMessages(input, limit: intLimit)
            while let message = messages.next() {
                guard message.name == name else { continue }
                guard message.isComplete else { break }
                return Data(message.bytes)
            }
        } else {
            let message = MessageSummary(MIMEPart(unwrapEMLX([UInt8](try input.read(limit: intLimit + 1)))[...]))
            if let attachment = message.namedAttachments.first(where: { $0.name == name }) {
                return Data(attachment.data)
            }
        }
        throw ExtractionError.invalidFormat("\(name) not found")
    }

    static func isMail(_ input: ExtractionInput) -> Bool {
        let ext = input.name.pathExtensionFast.lowercased()
        if ["eml", "emlx", "mbox"].contains(ext) {
            return true
        }
        guard let head = try? input.read(limit: 512) else { return false }
        let mime = MimeTypes.sniff(head)
        return mime == "message/rfc822" || mime == "application/mbox"
    }
}

/// The messages of a mailbox, in order, with the names they are indexed under. Messages start at
/// "From " lines (after a blank line, or at the start); ">From " lines in their bodies are
/// unescaped as in mboxrd. The file is read line by line: mailboxes can be many gigabytes.
struct MailboxMessages {
    struct Message {
        var name: String
        var subject: String
        var date: Date?
        /// The whole message, or its beginning when it is over the limit
        var bytes: [UInt8]
        var size: Int
        var isComplete: Bool
    }

    private var reader: LineReader
    private let limit: Int
    private var current: [UInt8] = []
    private var currentSize = 0
    private var started = false
    private var previousBlank = true
    private var finished = false
    private var count = 0
    private var used = Set<String>()

    static let fromLine = Array("From ".utf8)

    init(_ input: ExtractionInput, limit: Int) throws {
        reader = try LineReader(input)
        self.limit = limit
    }

    mutating func next() -> Message? {
        while !finished {
            guard let line = reader.next() else {
                finished = true
                return started ? complete() : nil
            }
            if previousBlank && line.starts(with: Self.fromLine) {
                let message = started ? complete() : nil
                started = true
                current.removeAll(keepingCapacity: true)
                currentSize = 0
                previousBlank = false
                if let message {
                    return message
                }
                continue
            }
            previousBlank = line.allSatisfy { $0 == 0x0A || $0 == 0x0D }
            guard started else { continue }
            var content = line[...]
            if content.first == 0x3E, content.drop(while: { $0 == 0x3E }).starts(with: Self.fromLine) {
                content = content.dropFirst()
            }
            currentSize += content.count
            // Over the limit, the beginning is kept for the header fields
            if current.count < max(limit, 65536) {
                current += content
            }
        }
        return nil
    }

    private mutating func complete() -> Message {
        count += 1
        let headers = MIMEPart(current[...])
        let subject = headers.header("subject") ?? ""
        let name = MailExtractor.uniqueName(
            String(format: "%05d ", count) + MailExtractor.fileName(subject, fallback: "message") + ".eml", used: &used)
        return Message(name: name, subject: subject, date: headers.header("date").flatMap(MailDate.parse),
                       bytes: current, size: currentSize, isComplete: currentSize <= limit)
    }
}

/// What indexing needs of a message, whatever format it comes in: MIME, or Outlook's .msg and
/// .pst, whose messages are turned into MIME (`rfc822`) to become members.
struct MessageSummary {
    var subject: String?
    var from: String?
    var to: String?
    var cc: String?
    var date: Date?
    var texts: [String] = []
    var attachments: [(name: String, data: [UInt8])] = []

    init() {}

    init(_ message: MIMEPart) {
        subject = message.header("subject")
        from = message.header("from")
        to = message.header("to")
        cc = message.header("cc")
        date = message.header("date").flatMap(MailDate.parse)
        var body = MailBody()
        body.collect(message, depth: 0)
        texts = body.texts
        attachments = body.attachments
    }

    /// Attachments under the names their members get: duplicates numbered
    var namedAttachments: [(name: String, data: [UInt8])] {
        var used = Set<String>()
        return attachments.map { (MailExtractor.uniqueName($0.name, used: &used), $0.data) }
    }

    func index(into result: inout Extracted, context: ExtractionContext) {
        result.title = subject
        result.setMetadata(MetaKey.emailFrom, from)
        result.setMetadata(MetaKey.emailTo, to)
        result.setMetadata(MetaKey.emailCc, cc)
        if let date {
            result.setMetadata(MetaKey.emailDate, date.formatted(.iso8601))
        }

        for (label, value) in [("From", from), ("To", to), ("Cc", cc), ("Date", date.map(MailDate.format))] {
            if let value, !value.isEmpty {
                result.content.appendLine("\(label): \(value)")
            }
        }
        for text in texts {
            result.content.appendLine(text)
        }
        if !attachments.isEmpty {
            result.content.appendLine("Attachments: " + attachments.map(\.name).joined(separator: ", "))
        }

        guard MailExtractor.emitsMembers(context) else { return }
        let mtime = date.map { Int64($0.timeIntervalSince1970) } ?? 0
        for attachment in namedAttachments {
            let tooLarge = Int64(attachment.data.count) > context.options.maxArchiveMemberSize
            context.parseMember(ArchiveMember(path: attachment.name, data: tooLarge ? nil : Data(attachment.data),
                                              mtime: mtime, size: Int64(attachment.data.count)))
        }
    }

    /// The message as RFC 5322 text: UTF-8 header fields as encoded words, the body as UTF-8 text,
    /// attachments as base64 parts.
    func rfc822() -> [UInt8] {
        var out = ""
        for (name, value) in [("From", from), ("To", to), ("Cc", cc), ("Subject", subject)] {
            if let value, !value.isEmpty {
                out += "\(name): \(HeaderText.encode(value))\r\n"
            }
        }
        if let date {
            out += "Date: \(MailDate.format(date))\r\n"
        }
        out += "MIME-Version: 1.0\r\n"
        let text = Self.base64(Array(texts.joined(separator: "\n\n").utf8))
        let textHeaders = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n"
        guard !attachments.isEmpty else {
            return Array((out + textHeaders + "\r\n" + text).utf8)
        }
        // "=" never occurs at the start of a base64 line, nor "_" in base64 at all
        let boundary = "=_sist_part_="
        out += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
        out += "--\(boundary)\r\n" + textHeaders + "\r\n" + text
        for attachment in attachments {
            let name = HeaderText.percentEncode(attachment.name)
            out += "--\(boundary)\r\nContent-Type: application/octet-stream\r\n"
            out += "Content-Disposition: attachment; filename*=utf-8''\(name)\r\n"
            out += "Content-Transfer-Encoding: base64\r\n\r\n" + Self.base64(attachment.data)
        }
        out += "--\(boundary)--\r\n"
        return Array(out.utf8)
    }

    static func base64(_ bytes: [UInt8]) -> String {
        let encoded = Data(bytes).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn,
                                                                  .endLineWithLineFeed])
        return encoded.isEmpty ? "" : encoded + "\r\n"
    }
}

/// What a message shows: its body texts and its attachments.
struct MailBody {
    var texts: [String] = []
    var attachments: [(name: String, data: [UInt8])] = []

    static let maxDepth = 16

    mutating func collect(_ part: MIMEPart, depth: Int) {
        guard depth < Self.maxDepth else { return }
        let type = part.contentType
        let disposition = part.disposition

        if type.value.hasPrefix("multipart/") {
            let parts = part.subparts()
            if type.value == "multipart/alternative" {
                // The plain version, else the HTML one, else whatever comes last
                let chosen = parts.first { $0.contentType.value == "text/plain" && !$0.isAttachment }
                    ?? parts.first { $0.contentType.value == "text/html" && !$0.isAttachment }
                    ?? parts.last
                if let chosen {
                    collect(chosen, depth: depth + 1)
                }
            } else {
                for subpart in parts {
                    collect(subpart, depth: depth + 1)
                }
            }
            return
        }

        if type.value == "message/rfc822" {
            let data = part.decodedBody()
            let subject = MIMEPart(data[...]).header("subject") ?? ""
            let name = part.filename ?? MailExtractor.fileName(subject, fallback: "message") + ".eml"
            attachments.append((name.hasSuffix(".eml") ? name : name + ".eml", data))
            return
        }

        if part.isAttachment {
            attachments.append((part.filename ?? "attachment-\(attachments.count + 1)", part.decodedBody()))
            return
        }

        guard type.value.hasPrefix("text/") || type.value.isEmpty, disposition != "attachment" else { return }
        let text = part.text()
        if type.value == "text/html" {
            texts.append(MarkupExtractor.strip(text).text)
        } else {
            texts.append(text)
        }
    }
}

/// One part of a message, or the message itself: header fields, then a body.
struct MIMEPart {
    /// Names lowercased, values unfolded and still encoded
    let headers: [(name: String, value: [UInt8])]
    let body: ArraySlice<UInt8>

    init(_ bytes: ArraySlice<UInt8>) {
        var headers: [(name: String, value: [UInt8])] = []
        var index = bytes.startIndex
        var bodyStart = bytes.endIndex
        while index < bytes.endIndex {
            let lineEnd = bytes[index...].firstIndex(of: 0x0A) ?? bytes.endIndex
            let next = min(lineEnd + 1, bytes.endIndex)
            var line = bytes[index..<lineEnd]
            if line.last == 0x0D {
                line = line.dropLast()
            }
            if line.isEmpty {
                bodyStart = next
                break
            }
            if line.first == 0x20 || line.first == 0x09 {
                // A folded line continues the previous field
                if !headers.isEmpty {
                    headers[headers.count - 1].value += line
                }
            } else if let colon = line.firstIndex(of: 0x3A), colon > line.startIndex,
                      !line[..<colon].contains(where: { $0 == 0x20 || $0 == 0x09 }) {
                let name = String(decoding: line[..<colon], as: UTF8.self).lowercased()
                headers.append((name, Array(line[(colon + 1)...].drop { $0 == 0x20 || $0 == 0x09 })))
            } else if headers.isEmpty {
                // No header block at all: everything is body
                bodyStart = bytes.startIndex
                break
            }
            index = next
        }
        self.headers = headers
        body = bodyStart < bytes.endIndex ? bytes[bodyStart...] : bytes[bytes.endIndex...]
    }

    /// The first field with this (lowercase) name, decoded
    func header(_ name: String) -> String? {
        guard let raw = headers.first(where: { $0.name == name })?.value else { return nil }
        return HeaderText.decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var contentType: HeaderText.Parameters {
        HeaderText.parameters(header("content-type") ?? "")
    }

    var disposition: String? {
        guard let value = header("content-disposition") else { return nil }
        return HeaderText.parameters(value).value
    }

    var filename: String? {
        let name = header("content-disposition").flatMap { HeaderText.parameters($0).parameters["filename"] }
            ?? contentType.parameters["name"]
        guard let name, !name.isEmpty else { return nil }
        return (name as NSString).lastPathComponent
    }

    /// An attachment rather than body text: so marked, or a named part that is not inline text
    var isAttachment: Bool {
        if disposition == "attachment" {
            return true
        }
        guard filename != nil else { return false }
        let type = contentType.value
        return !(disposition == "inline" && (type == "text/plain" || type == "text/html"))
    }

    func decodedBody() -> [UInt8] {
        switch header("content-transfer-encoding")?.lowercased() {
        case "base64": return Base64.decode(body)
        case "quoted-printable": return QuotedPrintable.decode(body)
        default: return Array(body)
        }
    }

    func text() -> String {
        let bytes = decodedBody()
        if let charset = contentType.parameters["charset"] {
            return HeaderText.decode(bytes, charset: charset)
        }
        return TextDecoding.decode(Data(bytes))
    }

    /// The parts of a multipart body, between its boundary lines
    func subparts() -> [MIMEPart] {
        guard let boundary = contentType.parameters["boundary"], !boundary.isEmpty else { return [] }
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [MIMEPart] = []
        var partStart: Int?
        var index = body.startIndex
        while index < body.endIndex {
            let lineEnd = body[index...].firstIndex(of: 0x0A) ?? body.endIndex
            let line = body[index..<lineEnd]
            if line.starts(with: delimiter) {
                if let start = partStart {
                    // The line break before the delimiter belongs to it
                    var end = index
                    if end > start, body[end - 1] == 0x0A { end -= 1 }
                    if end > start, body[end - 1] == 0x0D { end -= 1 }
                    parts.append(MIMEPart(body[start..<max(start, end)]))
                }
                if line.dropFirst(delimiter.count).starts(with: [0x2D, 0x2D]) {
                    return parts
                }
                partStart = min(lineEnd + 1, body.endIndex)
            }
            index = min(lineEnd + 1, body.endIndex)
        }
        // No closing delimiter: the last part runs to the end
        if let start = partStart, start < body.endIndex {
            parts.append(MIMEPart(body[start...]))
        }
        return parts
    }
}

/// Header field text: RFC 2047 encoded words, RFC 2231 parameters, and the charsets mail uses.
enum HeaderText {
    struct Parameters {
        /// Lowercased: "text/plain", "attachment"
        var value: String
        /// Keys lowercased, values decoded
        var parameters: [String: String]
    }

    /// Raw header bytes: ASCII with encoded words, but often 8-bit text from mailers that do not
    /// encode, in UTF-8 or the sender's code page.
    static func decode(_ raw: [UInt8]) -> String {
        decodeWords(TextDecoding.decodeName(raw))
    }

    /// Replaces `=?charset?B|Q?text?=` words. Whitespace between two of them is dropped, and the
    /// bytes of neighbouring words in the same charset are decoded together, since mailers cut
    /// words in the middle of a character.
    static func decodeWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        var out = ""
        var pending: (charset: String, bytes: [UInt8])?
        var whitespace = ""
        var index = text.startIndex

        func flush() {
            if let word = pending {
                out += decode(word.bytes, charset: word.charset)
                pending = nil
            }
            out += whitespace
            whitespace = ""
        }

        while index < text.endIndex {
            if text[index...].hasPrefix("=?"), let word = encodedWord(in: text, at: index) {
                whitespace = ""
                if pending?.charset == word.charset {
                    pending?.bytes += word.bytes
                } else {
                    flush()
                    pending = (word.charset, word.bytes)
                }
                index = word.end
                continue
            }
            let character = text[index]
            if pending != nil && (character == " " || character == "\t") {
                whitespace.append(character)
            } else {
                flush()
                out.append(character)
            }
            index = text.index(after: index)
        }
        flush()
        return out
    }

    static func encodedWord(in text: String, at start: String.Index) -> (charset: String, bytes: [UInt8], end: String.Index)? {
        let rest = text[text.index(start, offsetBy: 2)...]
        let parts = rest.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[1].count == 1,
              let close = parts[2].range(of: "?=") else { return nil }
        let encoded = parts[2][..<close.lowerBound]
        guard !encoded.contains(" ") else { return nil }
        // RFC 2231 adds a language: charset*lang
        let charset = String(parts[0].split(separator: "*").first ?? "")
        let bytes: [UInt8]
        switch parts[1].lowercased() {
        case "b": bytes = Base64.decode(Array(encoded.utf8))
        case "q": bytes = QuotedPrintable.decode(Array(encoded.utf8)[...], underscoreIsSpace: true)
        default: return nil
        }
        return (charset, bytes, close.upperBound)
    }

    static func decode(_ bytes: [UInt8], charset: String) -> String {
        if let encoding = encoding(forCharset: charset), let string = String(bytes: bytes, encoding: encoding) {
            return string
        }
        return TextDecoding.decode(Data(bytes))
    }

    static func encoding(forCharset charset: String) -> String.Encoding? {
        switch charset.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) {
        case "utf-8", "utf8", "us-ascii", "ascii": return .utf8
        case "gb2312", "gbk", "gb18030", "x-gbk", "cp936", "euc-cn", "x-euc-cn": return .gb18030
        case "big5", "big5-hkscs", "cp950", "x-x-big5": return .big5
        case "shift_jis", "shift-jis", "sjis", "x-sjis", "cp932", "windows-31j": return .shiftJIS
        case "euc-jp", "x-euc-jp": return .japaneseEUC
        case "iso-2022-jp": return .iso2022JP
        case "euc-kr", "ks_c_5601-1987", "cp949": return .windowsKorean
        case "iso-8859-1", "latin1", "iso8859-1": return .isoLatin1
        case "iso-8859-2", "latin2": return .isoLatin2
        case "windows-1250", "cp1250": return .windowsCP1250
        case "windows-1251", "cp1251": return .windowsCP1251
        case "windows-1252", "cp1252": return .windowsCP1252
        case "windows-1253", "cp1253": return .windowsCP1253
        case "windows-1254", "cp1254": return .windowsCP1254
        case "utf-16": return .utf16
        case "utf-16le": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        default: return nil
        }
    }

    /// `type/subtype; key=value; key="quoted value"`, with RFC 2231 values (`key*=utf-8''%E4%B8%AD`)
    /// and continuations (`key*0*=...; key*1*=...`).
    static func parameters(_ field: String) -> Parameters {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in field {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && quoted {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ";" && !quoted {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)

        let value = pieces.removeFirst().trimmingCharacters(in: .whitespaces).lowercased()
        var plain: [String: String] = [:]
        // name -> sections (number, value, percent-encoded)
        var extended: [String: [(Int, String, Bool)]] = [:]
        for piece in pieces {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let raw = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if key.contains("*") {
                var parts = key.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
                let encoded = parts.last == ""
                if encoded {
                    parts.removeLast()
                }
                let section = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                extended[parts[0], default: []].append((section, raw, encoded))
            } else {
                // Non-standard but common: encoded words inside a quoted file name
                plain[key] = decodeWords(raw)
            }
        }
        for (name, sections) in extended {
            var charset = "utf-8"
            var bytes: [UInt8] = []
            for (number, raw, encoded) in sections.sorted(by: { $0.0 < $1.0 }) {
                guard encoded else {
                    bytes += Array(raw.utf8)
                    continue
                }
                var text = Substring(raw)
                if number == 0 {
                    // charset'language'value
                    let fields = raw.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if fields.count == 3 {
                        if !fields[0].isEmpty {
                            charset = String(fields[0])
                        }
                        text = fields[2]
                    }
                }
                bytes += percentDecode(text)
            }
            plain[name] = decode(bytes, charset: charset)
        }
        return Parameters(value: value, parameters: plain)
    }

    /// A header value as an encoded word, unless it is plain ASCII
    static func encode(_ value: String) -> String {
        if value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) && !value.contains("=?") {
            return value
        }
        return "=?UTF-8?B?" + Data(value.utf8).base64EncodedString() + "?="
    }

    /// RFC 2231 / RFC 3986: everything but unreserved characters as %XX
    static func percentEncode(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E:
                out.append(Character(Unicode.Scalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func percentDecode(_ text: Substring) -> [UInt8] {
        let utf8 = Array(text.utf8)
        var out: [UInt8] = []
        var index = 0
        while index < utf8.count {
            if utf8[index] == 0x25, index + 2 < utf8.count,
               let high = QuotedPrintable.hexValue(utf8[index + 1]), let low = QuotedPrintable.hexValue(utf8[index + 2]) {
                out.append(high << 4 | low)
                index += 3
            } else {
                out.append(utf8[index])
                index += 1
            }
        }
        return out
    }
}

/// Base64 as mail uses it: line breaks, and whatever else is not in the alphabet, are skipped.
enum Base64 {
    static let values: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (value, character) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
            table[Int(character)] = UInt8(value)
        }
        table[Int(UInt8(ascii: "-"))] = 62  // base64url
        table[Int(UInt8(ascii: "_"))] = 63
        return table
    }()

    static func decode<Bytes: Collection>(_ input: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 3 / 4)
        var accumulator: UInt32 = 0
        var bits = 0
        for byte in input {
            let value = values[Int(byte)]
            guard value != 0xFF else { continue }
            accumulator = accumulator << 6 | UInt32(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
                accumulator &= (1 << UInt32(bits)) - 1
            }
        }
        return out
    }
}

enum QuotedPrintable {
    static func decode(_ input: ArraySlice<UInt8>, underscoreIsSpace: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var index = input.startIndex
        while index < input.endIndex {
            let byte = input[index]
            if byte == 0x3D {
                // A soft line break, with any trailing whitespace before it
                var next = index + 1
                while next < input.endIndex, input[next] == 0x20 || input[next] == 0x09 {
                    next += 1
                }
                if next < input.endIndex, input[next] == 0x0A {
                    index = next + 1
                    continue
                }
                if next + 1 < input.endIndex, input[next] == 0x0D, input[next + 1] == 0x0A {
                    index = next + 2
                    continue
                }
                if index + 2 < input.endIndex, let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) {
                    out.append(high << 4 | low)
                    index += 3
                    continue
                }
            }
            out.append(underscoreIsSpace && byte == 0x5F ? 0x20 : byte)
            index += 1
        }
        return out
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}

/// RFC 5322 dates (`Tue, 1 Jul 2003 10:52:37 +0200`) and the asctime ones of mbox "From " lines,
/// parsed by hand: DateFormatter is slow to make and not safe to share between parser threads.
enum MailDate {
    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    static let zones: [String: Int] = ["ut": 0, "utc": 0, "gmt": 0, "z": 0, "est": -5, "edt": -4, "cst": -6,
                                       "cdt": -5, "mst": -7, "mdt": -6, "pst": -8, "pdt": -7]

    /// `Tue, 05 Mar 2024 06:30:00 +0000`
    static func format(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let month = months[(c.month ?? 1) - 1].capitalized
        return String(format: "%@, %02d %@ %04d %02d:%02d:%02d +0000", days[(c.weekday ?? 1) - 1], c.day ?? 1, month,
                      c.year ?? 1970, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func parse(_ text: String) -> Date? {
        // Comments in parentheses, and the day of the week, carry nothing
        var cleaned = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 } else if character == ")" { depth = max(0, depth - 1) } else if depth == 0 {
                cleaned.append(character == "," ? " " : character)
            }
        }
        let tokens = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { String($0) }
        guard let monthIndex = tokens.firstIndex(where: { months.contains(String($0.prefix(3)).lowercased()) && $0.count >= 3 }),
              let month = months.firstIndex(of: String(tokens[monthIndex].prefix(3)).lowercased()) else { return nil }

        var day: Int?
        var year: Int?
        var time: String?
        var zone: String?
        if monthIndex > 0, let value = Int(tokens[monthIndex - 1]) {
            // 1 Jul 2003 10:52:37 +0200
            day = value
            year = tokens.indices.contains(monthIndex + 1) ? Int(tokens[monthIndex + 1]) : nil
            time = tokens.indices.contains(monthIndex + 2) ? tokens[monthIndex + 2] : nil
            zone = tokens.indices.contains(monthIndex + 3) ? tokens[monthIndex + 3] : nil
        } else if tokens.indices.contains(monthIndex + 3) {
            // Jul  1 10:52:37 2003 (asctime)
            day = Int(tokens[monthIndex + 1])
            time = tokens[monthIndex + 2]
            year = Int(tokens[monthIndex + 3])
            zone = tokens.indices.contains(monthIndex + 4) ? tokens[monthIndex + 4] : nil
        }
        guard let day, var year, (1...31).contains(day) else { return nil }
        if year < 50 { year += 2000 } else if year < 100 { year += 1900 }

        let clock = (time ?? "").split(separator: ":").compactMap { Int($0) }
        var offset = 0
        if let zone {
            if let sign = zone.first, sign == "+" || sign == "-", let value = Int(zone.dropFirst()), zone.count == 5 {
                offset = (value / 100 * 3600 + value % 100 * 60) * (sign == "-" ? -1 : 1)
            } else if let hours = zones[zone.lowercased()] {
                offset = hours * 3600
            }
        }
        var components = DateComponents()
        components.year = year
        components.month = month + 1
        components.day = day
        components.hour = clock.count > 0 ? clock[0] : 0
        components.minute = clock.count > 1 ? clock[1] : 0
        components.second = clock.count > 2 ? clock[2] : 0
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(secondsFromGMT: offset) else { return nil }
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }
}

/// Lines of a file or of data, with their line breaks, read a chunk at a time.
struct LineReader {
    private let handle: FileHandle?
    private var buffer: [UInt8]
    private var position = 0
    private var exhausted: Bool

    static let chunkSize = 1 << 20

    init(_ input: ExtractionInput) throws {
        switch input {
        case .data(let data, _):
            handle = nil
            buffer = [UInt8](data)
            exhausted = true
        case .file(let path):
            guard let handle = FileHandle(forReadingAtPath: path) else { throw ExtractionError.unreadable(path) }
            self.handle = handle
            buffer = []
            exhausted = false
        }
    }

    mutating func next() -> [UInt8]? {
        while true {
            if let newline = buffer[position...].firstIndex(of: 0x0A) {
                let line = Array(buffer[position...newline])
                position = newline + 1
                return line
            }
            if exhausted {
                guard position < buffer.count else {
                    try? handle?.close()
                    return nil
                }
                let line = Array(buffer[position...])
                position = buffer.count
                return line
            }
            buffer.removeSubrange(..<position)
            position = 0
            let chunk = (try? handle?.read(upToCount: Self.chunkSize)) ?? nil
            if let chunk, !chunk.isEmpty {
                buffer += chunk
            } else {
                exhausted = true
            }
        }
    }
}

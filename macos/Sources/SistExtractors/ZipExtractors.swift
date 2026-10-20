import Foundation
import SistCore
import ZIPFoundation

enum Zip {
    static func open(_ input: ExtractionInput) throws -> Archive {
        switch input {
        case .file(let path):
            return try Archive(url: URL(fileURLWithPath: path), accessMode: .read)
        case .data(let data, _):
            return try Archive(data: data, accessMode: .read)
        }
    }

    /// The whole entry, or nil when it is missing or bigger than `limit`.
    static func read(_ archive: Archive, _ path: String, limit: Int = 64 * 1024 * 1024) -> Data? {
        guard let entry = archive[path] else { return nil }
        return read(archive, entry, limit: limit)
    }

    static func read(_ archive: Archive, _ entry: Entry, limit: Int) -> Data? {
        guard entry.type == .file, entry.uncompressedSize <= UInt64(limit) else { return nil }
        var data = Data(capacity: Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry, skipCRC32: true) { chunk in
                data.append(chunk)
            }
        } catch {
            return nil
        }
        return data
    }
}

/// Word, Excel and PowerPoint documents (Office Open XML), as libscan's ooxml.c.
public struct OOXMLExtractor: Extractor {
    public init() {}

    public func accepts(mime: String, ext: String) -> Bool {
        mime.hasPrefix("application/vnd.openxmlformats-officedocument.")
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        let archive = try Zip.open(input)

        if let core = Zip.read(archive, "docProps/core.xml") {
            let values = firstXMLValues(core, names: ["title", "creator", "lastModifiedBy"])
            result.title = values["title"]
            result.setMetadata(MetaKey.author, values["creator"])
            result.setMetadata(MetaKey.modifiedBy, values["lastModifiedBy"])
        }

        let textElements: Set<String> = ["t"]
        let breakElements: Set<String> = ["p", "br", "tab", "si", "row"]

        for part in Self.textParts(of: archive) {
            guard !result.content.isFull, let data = Zip.read(archive, part) else { continue }
            collectXMLText(data, textElements: textElements, breakElements: breakElements, into: &result.content)
        }

        if context.options.thumbnailCount > 0,
           let thumbnail = Zip.read(archive, "docProps/thumbnail.jpeg") ?? Zip.read(archive, "docProps/thumbnail.png") {
            if let scaled = ImageScaling.thumbnail(from: thumbnail, options: context.options) {
                result.thumbnails.append(scaled)
            }
        }
    }

    /// The parts holding the text, in reading order.
    static func textParts(of archive: Archive) -> [String] {
        if archive["word/document.xml"] != nil {
            return ["word/document.xml", "word/footnotes.xml", "word/endnotes.xml"]
        }
        if archive["xl/sharedStrings.xml"] != nil {
            return ["xl/sharedStrings.xml"]
        }
        // ppt/slides/slide12.xml must come after slide2.xml
        func number(_ path: String) -> Int {
            Int(path.dropFirst("ppt/slides/slide".count).dropLast(".xml".count)) ?? 0
        }
        return archive
            .map(\.path)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { number($0) < number($1) }
    }
}

/// EPUB: the spine documents in reading order, title and author from the package document,
/// the cover image as thumbnail.
public struct EPUBExtractor: Extractor {
    public init() {}

    public func accepts(mime: String, ext: String) -> Bool {
        mime == "application/epub+zip"
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        let archive = try Zip.open(input)

        guard let container = Zip.read(archive, "META-INF/container.xml") else {
            throw ExtractionError.invalidFormat("no META-INF/container.xml")
        }
        var opfPath: String?
        let events = XMLEvents()
        events.onStart = { name, attributes in
            if name == "rootfile", opfPath == nil { opfPath = attributes["full-path"] }
        }
        events.parse(container)
        guard let opfPath, let opf = Zip.read(archive, opfPath) else {
            throw ExtractionError.invalidFormat("no package document")
        }
        let base = (opfPath as NSString).deletingLastPathComponent

        let package = Self.parsePackage(opf)
        result.title = package.title
        result.setMetadata(MetaKey.author, package.creator)

        for idref in package.spine {
            guard !result.content.isFull, let href = package.manifest[idref]?.href,
                  let data = Zip.read(archive, Self.resolve(href, base: base)) else { continue }
            result.content.appendLine(MarkupExtractor.strip(TextDecoding.decode(data)).text)
        }

        if context.options.thumbnailCount > 0, let coverHref = package.coverHref,
           let cover = Zip.read(archive, Self.resolve(coverHref, base: base)),
           let scaled = ImageScaling.thumbnail(from: cover, options: context.options) {
            result.thumbnails.append(scaled)
        }
    }

    struct Package {
        var title: String?
        var creator: String?
        var manifest: [String: (href: String, mediaType: String, properties: String)] = [:]
        var spine: [String] = []
        var coverId: String?

        var coverHref: String? {
            if let item = manifest.values.first(where: { $0.properties.split(separator: " ").contains("cover-image") }) {
                return item.href
            }
            return coverId.flatMap { manifest[$0]?.href }
        }
    }

    static func parsePackage(_ data: Data) -> Package {
        var package = Package()
        var current: String?
        var text = ""
        let events = XMLEvents()
        events.onStart = { name, attributes in
            switch name {
            case "title", "creator":
                current = name
                text = ""
            case "item":
                if let id = attributes["id"], let href = attributes["href"] {
                    package.manifest[id] = (href, attributes["media-type"] ?? "", attributes["properties"] ?? "")
                }
            case "itemref":
                if let idref = attributes["idref"] { package.spine.append(idref) }
            case "meta":
                if attributes["name"] == "cover" { package.coverId = attributes["content"] }
            default:
                break
            }
        }
        events.onEnd = { name in
            guard name == current else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "title" && package.title == nil && !value.isEmpty { package.title = value }
            if name == "creator" && package.creator == nil && !value.isEmpty { package.creator = value }
            current = nil
        }
        events.onText = { string in
            if current != nil { text += string }
        }
        events.parse(data)
        return package
    }

    static func resolve(_ href: String, base: String) -> String {
        let path = (href.removingPercentEncoding ?? href).components(separatedBy: "#")[0]
        let joined = base.isEmpty ? path : base + "/" + path
        // Collapse "dir/../x"
        var parts: [Substring] = []
        for part in joined.split(separator: "/") {
            if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(part) }
        }
        return parts.joined(separator: "/")
    }
}

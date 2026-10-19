import Foundation
import SistCore

/// Plain text, source code, CSV, subtitles, raw email. Only the bytes that can fill the content
/// buffer are read.
public struct PlainTextExtractor: Extractor {
    public init() {}

    public func accepts(mime: String, ext: String) -> Bool {
        mime.hasPrefix("text/") || mime == "message/rfc822" || mime == "application/mbox"
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        // A character is at most 4 bytes of UTF-8; whitespace collapsing needs some slack
        let data = try input.read(limit: context.options.contentSizeLimit * 4 + 1024)
        result.content.append(TextDecoding.decode(data))
    }
}

/// HTML, XHTML, XML and SVG: tags are dropped, `<script>`/`<style>` skipped, entities decoded.
public struct MarkupExtractor: Extractor {
    public init() {}

    static let mimes: Set<String> = ["text/html", "application/xhtml+xml", "text/xml", "application/xml",
                                     "image/svg+xml", "application/x-fictionbook+xml"]

    public func accepts(mime: String, ext: String) -> Bool {
        Self.mimes.contains(mime)
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        let data = try input.read(limit: context.options.contentSizeLimit * 16 + 65536)
        let (title, text) = Self.strip(TextDecoding.decode(data))
        result.title = title
        result.content.append(text)
    }

    static let blockTags: Set<String> = ["p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
                                         "section", "article", "blockquote", "pre", "table", "ul", "ol", "dd", "dt"]

    /// Returns the `<title>` and the text of a markup document.
    public static func strip(_ markup: String) -> (title: String?, text: String) {
        var out = ""
        var title: String?
        var i = markup.startIndex
        let end = markup.endIndex

        func skip(past terminator: String, from index: String.Index) -> String.Index {
            markup.range(of: terminator, options: .caseInsensitive, range: index..<end)?.upperBound ?? end
        }

        while i < end {
            let c = markup[i]
            guard c == "<" else {
                let next = markup[i...].firstIndex(of: "<") ?? end
                out += decodeEntities(String(markup[i..<next]))
                i = next
                continue
            }
            let rest = markup[i...]
            if rest.hasPrefix("<!--") {
                i = skip(past: "-->", from: i)
                continue
            }
            if rest.hasPrefix("<![CDATA[") {
                let contentStart = markup.index(i, offsetBy: 9)
                let close = markup.range(of: "]]>", range: contentStart..<end)
                out += String(markup[contentStart..<(close?.lowerBound ?? end)])
                i = close?.upperBound ?? end
                continue
            }
            guard let tagEnd = markup[i...].firstIndex(of: ">") else { break }
            let tag = markup[markup.index(after: i)..<tagEnd]
            let tagName = tag.drop(while: { $0 == "/" })
                .prefix(while: { $0.isLetter || $0.isNumber || $0 == ":" })
                .lowercased()
            i = markup.index(after: tagEnd)

            switch tagName {
            case "script", "style", "noscript", "template":
                if !tag.hasSuffix("/") {
                    i = skip(past: "</\(tagName)", from: i)
                    i = markup[i...].firstIndex(of: ">").map { markup.index(after: $0) } ?? end
                }
            case "title" where !tag.hasPrefix("/"):
                let close = markup.range(of: "</title", options: .caseInsensitive, range: i..<end)
                let text = decodeEntities(String(markup[i..<(close?.lowerBound ?? end)]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if title == nil && !text.isEmpty {
                    title = text
                }
                i = close.flatMap { markup[$0.upperBound...].firstIndex(of: ">") }.map { markup.index(after: $0) } ?? end
            default:
                let local = tagName.split(separator: ":").last.map(String.init) ?? tagName
                out += blockTags.contains(local) ? "\n" : " "
            }
        }
        return (title, out)
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©",
        "reg": "®", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "middot": "·", "times": "×", "deg": "°", "euro": "€", "yen": "¥",
    ]

    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            guard c == "&", let semicolon = text[i...].prefix(12).firstIndex(of: ";") else {
                out.append(c)
                i = text.index(after: i)
                continue
            }
            let entity = text[text.index(after: i)..<semicolon]
            var decoded: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if entity.hasPrefix("#") {
                decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                decoded = namedEntities[String(entity)]
            }
            if let decoded {
                out += decoded
                i = text.index(after: semicolon)
            } else {
                out.append(c)
                i = text.index(after: i)
            }
        }
        return out
    }
}

/// JSON and newline-delimited JSON: the string values become the content, as in sist2.
public struct JSONExtractor: Extractor {
    public init() {}

    public func accepts(mime: String, ext: String) -> Bool {
        mime == "application/json" || mime == "application/x-ndjson"
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        let data = try input.read(limit: 64 * 1024 * 1024)
        let documents: [Data]
        if context.path.pathExtensionFast == "json" {
            documents = [data]
        } else {
            documents = data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
        }

        var parsedAny = false
        for document in documents where !result.content.isFull {
            guard let object = try? JSONSerialization.jsonObject(with: document, options: [.fragmentsAllowed]) else {
                continue
            }
            parsedAny = true
            Self.collectStrings(object, into: &result.content)
        }
        if !parsedAny {
            // Not actually JSON: index it as text
            result.content.append(TextDecoding.decode(data.prefix(context.options.contentSizeLimit * 4)))
        }
    }

    static func collectStrings(_ value: Any, into buffer: inout ContentBuffer) {
        if buffer.isFull { return }
        switch value {
        case let string as String:
            buffer.append(string)
        case let array as [Any]:
            for item in array { collectStrings(item, into: &buffer) }
        case let dictionary as [String: Any]:
            for key in dictionary.keys.sorted() { collectStrings(dictionary[key]!, into: &buffer) }
        default:
            break
        }
    }
}

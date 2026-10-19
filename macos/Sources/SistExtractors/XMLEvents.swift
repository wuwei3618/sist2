import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Callback-style SAX parsing over XMLParser. Element names are local names (prefix dropped).
final class XMLEvents: NSObject, XMLParserDelegate {
    var onStart: ((_ name: String, _ attributes: [String: String]) -> Void)?
    var onEnd: ((_ name: String) -> Void)?
    var onText: ((_ text: String) -> Void)?
    /// Checked after every event; true stops the parse
    var shouldStop: (() -> Bool)?

    /// Returns false when the document is not well-formed (whatever was read before the error has
    /// already been delivered).
    @discardableResult
    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        return parser.parse()
    }

    static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        onStart?(Self.localName(elementName), attributeDict)
        stopIfNeeded(parser)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        onEnd?(Self.localName(elementName))
        stopIfNeeded(parser)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        onText?(string)
        stopIfNeeded(parser)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        onText?(String(decoding: CDATABlock, as: UTF8.self))
        stopIfNeeded(parser)
    }

    private func stopIfNeeded(_ parser: XMLParser) {
        if shouldStop?() == true {
            parser.abortParsing()
        }
    }
}

/// Text of the elements named in `textElements`, with a line break after each `breakElements`.
func collectXMLText(_ data: Data, textElements: Set<String>, breakElements: Set<String>,
                    into buffer: inout ContentBuffer) {
    var collected = ContentBuffer(limit: buffer.limit)
    var inside = 0
    var paragraph = ""
    let events = XMLEvents()
    events.onStart = { name, _ in
        if textElements.contains(name) { inside += 1 }
    }
    events.onEnd = { name in
        if textElements.contains(name) { inside = max(0, inside - 1) }
        if breakElements.contains(name) {
            collected.appendLine(paragraph)
            paragraph = ""
        }
    }
    events.onText = { text in
        if inside > 0 { paragraph += text }
    }
    events.shouldStop = { collected.isFull }
    events.parse(data)
    if !paragraph.isEmpty {
        collected.appendLine(paragraph)
    }
    buffer.appendLine(collected.text)
}

/// Text of the first occurrence of each named element, e.g. Dublin Core properties.
func firstXMLValues(_ data: Data, names: Set<String>) -> [String: String] {
    var values: [String: String] = [:]
    var current: String?
    var text = ""
    let events = XMLEvents()
    events.onStart = { name, _ in
        if names.contains(name) && values[name] == nil {
            current = name
            text = ""
        }
    }
    events.onEnd = { name in
        if name == current {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { values[name] = trimmed }
            current = nil
        }
    }
    events.onText = { string in
        if current != nil { text += string }
    }
    events.parse(data)
    return values
}

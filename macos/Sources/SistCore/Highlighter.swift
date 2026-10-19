import Foundation

/// A piece of text with the parts that matched the query marked.
public struct Snippet: Sendable, Hashable, Codable {
    public struct Segment: Sendable, Hashable, Codable {
        public var text: String
        public var highlighted: Bool

        public init(text: String, highlighted: Bool) {
            self.text = text
            self.highlighted = highlighted
        }
    }

    public var segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    public var plainText: String { segments.map(\.text).joined() }
    public var hasHighlights: Bool { segments.contains { $0.highlighted } }
}

/// Finds query terms in original text. The FTS index holds rewritten text (see SearchText), so
/// excerpts are cut and marked here, from the stored content, as sist2's highlight.c does.
public enum Highlighter {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    static let maxMatches = 2_000

    /// Marks every occurrence of the terms in `text`.
    public static func highlight(_ text: String, terms: [String]) -> Snippet {
        let ranges = matches(in: text, terms: terms)
        return build(text, window: text.startIndex..<text.endIndex, matches: ranges, singleLine: false)
    }

    /// An excerpt of about `length` characters around the densest cluster of matches, or the
    /// beginning of the text when nothing matches (the document matched on its name or path).
    public static func excerpt(_ text: String, terms: [String], length: Int = 240) -> Snippet? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let ranges = matches(in: trimmed, terms: terms)
        guard !ranges.isEmpty else {
            let end = trimmed.index(trimmed.startIndex, offsetBy: length, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            return build(trimmed, window: trimmed.startIndex..<end, matches: [], singleLine: true)
        }

        // Character offsets of the matches, computed incrementally (they are sorted)
        var offsets: [(start: Int, term: Int)] = []
        var cursor = trimmed.startIndex
        var cursorOffset = 0
        for match in ranges {
            cursorOffset += trimmed.distance(from: cursor, to: match.range.lowerBound)
            cursor = match.range.lowerBound
            offsets.append((cursorOffset, match.term))
        }

        // The window starting a little before a match that covers the most distinct terms, then
        // the most matches
        var best = (start: 0, distinct: 0, count: 0)
        var j = 0
        for i in offsets.indices {
            j = max(j, i)
            while j + 1 < offsets.count && offsets[j + 1].start < offsets[i].start + length * 3 / 4 {
                j += 1
            }
            let distinct = Set(offsets[i...j].map(\.term)).count
            let count = j - i + 1
            if distinct > best.distinct || (distinct == best.distinct && count > best.count) {
                best = (i, distinct, count)
            }
        }

        let windowStartOffset = max(0, offsets[best.start].start - length / 4)
        let start = trimmed.index(trimmed.startIndex, offsetBy: windowStartOffset)
        let end = trimmed.index(start, offsetBy: length, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
        var snippet = build(trimmed, window: start..<end, matches: ranges, singleLine: true)
        if start > trimmed.startIndex {
            snippet.segments.insert(.init(text: "…", highlighted: false), at: 0)
        }
        if end < trimmed.endIndex {
            snippet.segments.append(.init(text: "…", highlighted: false))
        }
        return snippet
    }

    struct Match {
        var range: Range<String.Index>
        var term: Int
    }

    static func matches(in text: String, terms: [String]) -> [Match] {
        var found: [Match] = []
        let needles = terms
            .map { SearchText.normalize($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for (termIndex, needle) in needles.enumerated() {
            var searchStart = text.startIndex
            while searchStart < text.endIndex, found.count < maxMatches,
                  let range = text.range(of: needle, options: options, range: searchStart..<text.endIndex) {
                found.append(Match(range: range, term: termIndex))
                searchStart = range.upperBound
            }
        }
        found.sort { $0.range.lowerBound < $1.range.lowerBound }

        // Overlapping matches of different terms are merged into the first one
        var merged: [Match] = []
        for match in found {
            if let last = merged.last, match.range.lowerBound < last.range.upperBound {
                if match.range.upperBound > last.range.upperBound {
                    merged[merged.count - 1].range = last.range.lowerBound..<match.range.upperBound
                }
            } else {
                merged.append(match)
            }
        }
        return merged
    }

    static func build(_ text: String, window: Range<String.Index>, matches: [Match], singleLine: Bool) -> Snippet {
        var segments: [Snippet.Segment] = []
        var cursor = window.lowerBound
        for match in matches {
            let lower = max(match.range.lowerBound, window.lowerBound)
            let upper = min(match.range.upperBound, window.upperBound)
            guard lower < upper else { continue }
            if cursor < lower {
                segments.append(.init(text: String(text[cursor..<lower]), highlighted: false))
            }
            segments.append(.init(text: String(text[lower..<upper]), highlighted: true))
            cursor = upper
        }
        if cursor < window.upperBound {
            segments.append(.init(text: String(text[cursor..<window.upperBound]), highlighted: false))
        }
        // Excerpts are shown on one or two lines
        for i in segments.indices where singleLine {
            segments[i].text = segments[i].text.replacingOccurrences(of: "\n", with: " ")
        }
        return Snippet(segments: segments)
    }
}

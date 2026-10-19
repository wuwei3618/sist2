import Foundation

/// Turns what the user types into an FTS5 MATCH expression.
///
/// The syntax is deliberately small and forgiving, so that no input can produce an FTS5 syntax
/// error:
///
///     word            documents containing the word (CJK substrings work, see SearchText)
///     "two words"     phrase
///     pre*            prefix
///     -word           exclude
///     a OR b, a | b   either
///     name:report     restrict a term to a column: name, title, content, path
///
/// Terms are ANDed. `OR` binds the terms on each side of it, so `a b OR c d` means
/// `a AND (b OR c) AND d`.
public struct ParsedQuery: Sendable, Hashable {
    /// nil when the query has nothing to match on (empty, punctuation only, or only exclusions)
    public var ftsExpression: String?
    /// Raw strings to mark in names, excerpts and previews
    public var highlightTerms: [String]
}

public enum QueryParser {
    static let columns: Set<String> = ["name", "title", "content", "path"]

    struct Term {
        var text: String
        var negated = false
        var prefix = false
        var column: String?
        var orWithPrevious = false
    }

    public static func parse(_ input: String) -> ParsedQuery {
        let terms = tokenize(input)
        var groups: [[String]] = []
        var negatives: [String] = []
        var highlights: [String] = []

        for term in terms {
            guard let phrase = ftsPhrase(for: term) else { continue }
            if term.negated {
                negatives.append(phrase)
                continue
            }
            highlights.append(term.text)
            if term.orWithPrevious, !groups.isEmpty {
                groups[groups.count - 1].append(phrase)
            } else {
                groups.append([phrase])
            }
        }

        guard !groups.isEmpty else {
            return ParsedQuery(ftsExpression: nil, highlightTerms: [])
        }

        var expression = groups
            .map { $0.count == 1 ? $0[0] : "(" + $0.joined(separator: " OR ") + ")" }
            .joined(separator: " AND ")
        if !negatives.isEmpty {
            expression = "(\(expression)) NOT (" + negatives.joined(separator: " OR ") + ")"
        }
        return ParsedQuery(ftsExpression: expression, highlightTerms: highlights)
    }

    static func ftsPhrase(for term: Term) -> String? {
        guard SearchText.containsTokenCharacter(term.text) else { return nil }
        let (text, cjkPrefix) = SearchText.queryPhrase(term.text)
        let quoted = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let phrase = quoted + (term.prefix || cjkPrefix ? "*" : "")
        if let column = term.column {
            return "\(column) : \(phrase)"
        }
        return phrase
    }

    static func tokenize(_ input: String) -> [Term] {
        var terms: [Term] = []
        var pendingOr = false
        let chars = Array(input)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
                continue
            }
            if c == "|" {
                pendingOr = true
                i += 1
                continue
            }

            var term = Term(text: "")
            if c == "-" && i + 1 < chars.count && !chars[i + 1].isWhitespace {
                term.negated = true
                i += 1
            }

            // column:...
            if let colon = chars[i...].firstIndex(where: { $0 == ":" || $0.isWhitespace || $0 == "\"" }),
               chars[colon] == ":" {
                let name = String(chars[i..<colon]).lowercased()
                if columns.contains(name) && colon + 1 < chars.count && !chars[colon + 1].isWhitespace {
                    term.column = name
                    i = colon + 1
                }
            }

            if chars[i] == "\"" {
                let start = i + 1
                var end = start
                while end < chars.count && chars[end] != "\"" {
                    end += 1
                }
                term.text = String(chars[start..<min(end, chars.count)])
                i = end + 1
                if i < chars.count && chars[i] == "*" {
                    term.prefix = true
                    i += 1
                }
            } else {
                let start = i
                while i < chars.count && !chars[i].isWhitespace && chars[i] != "|" {
                    i += 1
                }
                var word = String(chars[start..<i])
                if word.hasSuffix("*") {
                    term.prefix = true
                    word = String(word.dropLast()).trimmingTrailing("*")
                }
                if word == "OR" && term.column == nil && !term.negated {
                    pendingOr = true
                    continue
                }
                term.text = word
            }

            term.orWithPrevious = pendingOr && !term.negated
            pendingOr = false
            terms.append(term)
        }
        return terms
    }
}

extension String {
    func trimmingTrailing(_ character: Character) -> String {
        var s = Substring(self)
        while s.last == character {
            s = s.dropLast()
        }
        return String(s)
    }
}

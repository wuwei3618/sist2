import Foundation

/// Makes CJK text searchable with SQLite's `unicode61` tokenizer.
///
/// `unicode61` splits on separators only, so a run of Chinese or Japanese characters becomes one
/// giant token and searching for a word inside it finds nothing. Text is therefore rewritten
/// before it reaches FTS5: every CJK character becomes a token of its own (`文档管理` →
/// `文 档 管 理`), and a query is the phrase of its characters, which matches a substring of any
/// length. Other scripts are left to `unicode61`.
///
/// Overlapping bigrams (`文档 档管 管理`), the usual alternative, make phrase queries on common
/// words faster but the index twice as large and writes four times slower, and a single character
/// can then only be found as a slow prefix query. Measured on 96,000 Wikipedia and Wikinews
/// articles (600 MB of Chinese text): 436 MB instead of 788 MB of index, 15–150 ms instead of
/// 1–35 ms for multi-character words, 160 ms instead of 1.7 s for `的`.
public enum SearchText {
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,   // Hangul Jamo
             0x2E80...0x2FDF,   // CJK radicals, Kangxi radicals
             0x3005...0x3007,   // 々 〆 〇
             0x3040...0x30FF,   // Hiragana, Katakana
             0x3100...0x312F,   // Bopomofo
             0x3130...0x318F,   // Hangul compatibility Jamo
             0x31A0...0x31BF,   // Bopomofo extended
             0x31F0...0x31FF,   // Katakana phonetic extensions
             0x3400...0x4DBF,   // CJK extension A
             0x4E00...0x9FFF,   // CJK unified ideographs
             0xA960...0xA97F,   // Hangul Jamo extended A
             0xAC00...0xD7FF,   // Hangul syllables, Jamo extended B
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFF66...0xFF9F,   // Halfwidth Katakana (NFKC maps them, kept for safety)
             0x20000...0x3134F: // CJK extensions B-G
            return true
        default:
            return false
        }
    }

    /// Whether `unicode61` keeps this scalar inside a token (letters, numbers, private use)
    public static func isTokenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .privateUse:
            return true
        default:
            return false
        }
    }

    /// NFKC folds full-width Latin, half-width Katakana and compatibility ideographs, so that
    /// `ＡＢＣ` finds `ABC`. Applied to both indexed text and queries.
    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    /// The text stored in the FTS index for `text`.
    public static func indexable(_ text: String) -> String {
        separatingCJK(normalize(text))
    }

    /// Rewrites one query term (a word or a quoted phrase) into the text of an FTS5 phrase.
    public static func queryPhrase(_ term: String) -> String {
        separatingCJK(normalize(term)).trimmingCharacters(in: .whitespaces)
    }

    private static func separatingCJK(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var previousWasCJK = false
        for scalar in text.unicodeScalars {
            let cjk = isCJK(scalar)
            if cjk && !previousWasCJK {
                out.append(" ")
            }
            out.append(scalar)
            if cjk {
                out.append(" ")
            }
            previousWasCJK = cjk
        }
        return String(out)
    }

    /// The full-text row of a document of a source rooted at `root`. The path column holds the
    /// folders between the root and the document only: the name has its own column, and the root
    /// itself would match every document.
    public static func indexedText(for document: ParsedDocument, root: String) -> IndexedText {
        let rootPrefix = root == "/" ? "/" : root + "/"
        var directory = (document.path as NSString).deletingLastPathComponent
        if directory.hasPrefix(rootPrefix) {
            directory.removeFirst(rootPrefix.count)
        } else if directory + "/" == rootPrefix {
            directory = ""
        }
        return IndexedText(name: indexable(document.name), title: document.title.map(indexable),
                           content: document.content.map(indexable), path: indexable(directory))
    }

    public static func containsTokenCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { isTokenCharacter($0) }
    }
}

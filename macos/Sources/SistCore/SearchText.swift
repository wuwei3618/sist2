import Foundation

/// Makes CJK text searchable with SQLite's `unicode61` tokenizer.
///
/// `unicode61` splits on separators only, so a run of Chinese or Japanese characters becomes one
/// giant token and searching for a word inside it finds nothing. Text is therefore rewritten
/// before it reaches FTS5: every CJK run becomes its overlapping bigrams followed by its last
/// character on its own (`文档管理` → `文档 档管 管理 理`). Other scripts are left to `unicode61`.
///
/// Queries are rewritten the same way (see `queryPhrase`) so that a CJK substring of any length
/// matches as a phrase of consecutive bigrams.
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
        let normalized = normalize(text)
        var out = String.UnicodeScalarView()
        var run: [Unicode.Scalar] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            out.append(" ")
            appendBigrams(of: run, trailingUnigram: true, to: &out)
            out.append(" ")
            run.removeAll(keepingCapacity: true)
        }

        for scalar in normalized.unicodeScalars {
            if isCJK(scalar) {
                run.append(scalar)
            } else {
                flushRun()
                out.append(scalar)
            }
        }
        flushRun()
        return String(out)
    }

    /// Rewrites one query term (a word or a quoted phrase) into the text of an FTS5 phrase.
    ///
    /// A CJK run at the end of the term emits its bigrams only, because the matching text may
    /// continue past it; a run followed by more tokens must end where the indexed run ends, so it
    /// also emits the trailing unigram, exactly as `indexable` does. A single CJK character at the
    /// end can only be matched as a prefix (`文` must find `文档`), which `prefix` reports.
    public static func queryPhrase(_ term: String) -> (text: String, prefix: Bool) {
        let scalars = Array(normalize(term).unicodeScalars)
        var out = String.UnicodeScalarView()
        var prefix = false
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            guard isCJK(scalar) else {
                out.append(scalar)
                index += 1
                continue
            }
            var end = index
            while end < scalars.count && isCJK(scalars[end]) {
                end += 1
            }
            let run = Array(scalars[index..<end])
            let followedByToken = scalars[end...].contains { isTokenCharacter($0) }

            out.append(" ")
            if followedByToken {
                appendBigrams(of: run, trailingUnigram: true, to: &out)
            } else if run.count == 1 {
                out.append(run[0])
                prefix = true
            } else {
                appendBigrams(of: run, trailingUnigram: false, to: &out)
            }
            out.append(" ")
            index = end
        }
        return (String(out).trimmingCharacters(in: .whitespaces), prefix)
    }

    private static func appendBigrams(of run: [Unicode.Scalar], trailingUnigram: Bool,
                                      to out: inout String.UnicodeScalarView) {
        if run.count == 1 {
            out.append(run[0])
            return
        }
        for i in 0..<(run.count - 1) {
            if i > 0 { out.append(" ") }
            out.append(run[i])
            out.append(run[i + 1])
        }
        if trailingUnigram {
            out.append(" ")
            out.append(run[run.count - 1])
        }
    }

    public static func containsTokenCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { isTokenCharacter($0) }
    }
}

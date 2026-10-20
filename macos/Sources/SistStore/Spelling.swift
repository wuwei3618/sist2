import Foundation
import GRDB

/// Typo correction against the words of the full-text index (`document_vocab`).
enum Spelling {
    /// The indexed word closest to `word`, when `word` is a plain Latin word the index does not
    /// have: at most one edit away for short words, two for longer ones; among equally close
    /// words, the one in most documents. Words are assumed to start with the right letter, which
    /// keeps the candidates to one slice of the vocabulary.
    static func correction(for word: String, in db: Database) throws -> String? {
        let term = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard term.count >= 3, term.count <= 40,
              term.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) }),
              let first = term.unicodeScalars.first else { return nil }
        let known = try Bool.fetchOne(db, sql: "SELECT 1 FROM document_vocab WHERE term = ?", arguments: [term]) ?? false
        guard !known else { return nil }

        let maxDistance = term.count <= 4 ? 1 : 2
        let target = Array(term.utf8)
        let next = String(Character(Unicode.Scalar(first.value + 1)!))
        var best: (term: String, distance: Int, documents: Int)?
        let rows = try Row.fetchCursor(db, sql: """
            SELECT term, doc FROM document_vocab WHERE term >= ? AND term < ? AND length(term) BETWEEN ? AND ?
            """, arguments: [String(first), next, term.count - maxDistance, term.count + maxDistance])
        while let row = try rows.next() {
            let candidate: String = row["term"]
            let documents: Int = row["doc"]
            guard let distance = distance(target, Array(candidate.utf8), limit: maxDistance) else { continue }
            if best == nil || distance < best!.distance || (distance == best!.distance && documents > best!.documents) {
                best = (candidate, distance, documents)
            }
        }
        return best?.term
    }

    /// Optimal string alignment distance (insertions, deletions, substitutions, transpositions of
    /// neighbours), or nil once it is certain to be over `limit`
    static func distance(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int? {
        guard abs(a.count - b.count) <= limit else { return nil }
        if a.isEmpty || b.isEmpty {
            return max(a.count, b.count)
        }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit {
                return nil
            }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count] <= limit ? previous[b.count] : nil
    }
}

import Foundation

/// gitignore-style rules read from `.sistignore` (or sist2's `.sist2ignore`) at the root of a source.
///
/// Supported: comments, blank lines, `!` negation, `/`-anchored patterns, trailing `/` for
/// directories only, `*`, `?`, `[...]` and `**`. The last matching rule wins, as in git.
public struct IgnoreList: Sendable {
    public static let fileNames = [".sistignore", ".sist2ignore"]

    struct Rule: @unchecked Sendable {
        // NSRegularExpression is immutable and documented as thread safe
        var regex: NSRegularExpression
        var negated: Bool
        var directoryOnly: Bool
    }

    private let root: String
    private let rules: [Rule]

    public var isEmpty: Bool { rules.isEmpty }

    public init(root: String, patterns: [String]) {
        self.root = root.hasSuffix("/") ? String(root.dropLast()) : root
        self.rules = patterns.compactMap(IgnoreList.compile)
    }

    /// Reads the ignore file at the root of a source, if there is one.
    public static func load(root: String) -> IgnoreList {
        var patterns: [String] = []
        for name in fileNames {
            let path = (root as NSString).appendingPathComponent(name)
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                patterns += text.components(separatedBy: .newlines)
            }
        }
        return IgnoreList(root: root, patterns: patterns)
    }

    /// `path` is absolute and below the root.
    public func isIgnored(_ path: String, isDirectory: Bool) -> Bool {
        guard !rules.isEmpty, path.hasPrefix(root) else { return false }
        let relative = String(path.dropFirst(root.count).drop(while: { $0 == "/" }))
        guard !relative.isEmpty else { return false }

        var ignored = false
        let range = NSRange(relative.startIndex..<relative.endIndex, in: relative)
        for rule in rules {
            if rule.directoryOnly && !isDirectory { continue }
            if rule.regex.firstMatch(in: relative, options: [], range: range) != nil {
                ignored = !rule.negated
            }
        }
        return ignored
    }

    static func compile(_ line: String) -> Rule? {
        var pattern = line.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return nil }

        var negated = false
        if pattern.hasPrefix("!") {
            negated = true
            pattern.removeFirst()
        }
        if pattern.hasPrefix("\\") {
            pattern.removeFirst()
        }
        var directoryOnly = false
        if pattern.hasSuffix("/") {
            directoryOnly = true
            pattern.removeLast()
        }
        // A slash anywhere but at the end anchors the pattern to the root
        let anchored = pattern.contains("/")
        if pattern.hasPrefix("/") {
            pattern.removeFirst()
        }
        guard !pattern.isEmpty else { return nil }

        let body = globToRegex(pattern)
        let regex = anchored ? "^" + body + "$" : "(^|/)" + body + "$"
        guard let compiled = try? NSRegularExpression(pattern: regex, options: []) else { return nil }
        return Rule(regex: compiled, negated: negated, directoryOnly: directoryOnly)
    }

    static func globToRegex(_ glob: String) -> String {
        var out = ""
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    // `**/` matches zero or more directories, a trailing `**` everything below
                    if i + 2 < chars.count && chars[i + 2] == "/" {
                        out += "(.*/)?"
                        i += 3
                    } else {
                        out += ".*"
                        i += 2
                    }
                    continue
                }
                out += "[^/]*"
            case "?":
                out += "[^/]"
            case "[":
                if let close = chars[(i + 1)...].firstIndex(of: "]") {
                    var set = String(chars[(i + 1)..<close])
                    if set.hasPrefix("!") {
                        set = "^" + set.dropFirst()
                    }
                    out += "[" + set.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    i = close + 1
                    continue
                }
                out += "\\["
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        return out
    }
}

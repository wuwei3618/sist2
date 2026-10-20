import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Finder tags: the `com.apple.metadata:_kMDItemUserTags` extended attribute, a binary property
/// list of strings, each a tag name optionally followed by a newline and a colour number. Read
/// with one getxattr per file during the walk; other systems have none.
public enum FinderTags {
    public static let attribute = "com.apple.metadata:_kMDItemUserTags"

    public static func read(path: String) -> [String]? {
        #if canImport(Darwin)
        let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read > 0 else { return nil }
        return decode(data.prefix(read))
        #else
        return nil
        #endif
    }

    public static func decode(_ data: Data) -> [String]? {
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            return nil
        }
        let names = list.compactMap { $0.split(separator: "\n", maxSplits: 1).first.map(String.init) }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names
    }

    /// How the catalog stores a set of tags (sorted, one per line), nil for none
    public static func key(_ tags: [String]?) -> String? {
        guard let tags, !tags.isEmpty else { return nil }
        return Set(tags).sorted().joined(separator: "\n")
    }
}

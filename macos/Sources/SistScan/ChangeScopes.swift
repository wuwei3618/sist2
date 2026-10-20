import Foundation
import SistCore

/// A change FSEvents reported under a source.
public struct FileChange: Sendable, Hashable {
    public var path: String
    public var isDirectory: Bool
    /// FSEvents lost track (dropped events, or it asks for a rescan of the subtree)
    public var mustRescanSubtree: Bool

    public init(path: String, isDirectory: Bool, mustRescanSubtree: Bool = false) {
        self.path = path
        self.isDirectory = isDirectory
        self.mustRescanSubtree = mustRescanSubtree
    }
}

public enum ChangeScopes {
    /// The directories to rescan after `changes`: a changed file's folder without its subfolders
    /// (that catches files added, modified and removed), a changed folder with everything below it
    /// (a folder moved in or out brings no event per file). nil, a scan of the whole source, when
    /// FSEvents lost track of the root or there are too many changes to be worth sorting out.
    public static func scopes(for changes: [FileChange], root: String, limit: Int = 500) -> [ScanScope]? {
        let rootPrefix = root == "/" ? "/" : root + "/"
        var scopes = Set<ScanScope>()
        for change in changes {
            if change.mustRescanSubtree || change.isDirectory {
                guard change.path != root, change.path.hasPrefix(rootPrefix) else { return nil }
                scopes.insert(ScanScope(path: change.path, recursive: true))
            } else {
                scopes.insert(ScanScope(path: (change.path as NSString).deletingLastPathComponent, recursive: false))
            }
            if scopes.count > limit {
                return nil
            }
        }
        return scopes.sorted { $0.path < $1.path }
    }
}

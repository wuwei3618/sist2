import Foundation
import GRDB
import SistCore

/// A folder the user indexes (a sist2 "index").
public struct Source: Sendable, Hashable, Identifiable, FetchableRecord {
    public var id: Int64
    public var name: String
    public var root: String
    public var options: ScanOptions
    public var createdAt: Date
    public var lastScanAt: Date?
    public var lastScanId: Int64?

    public init(row: Row) throws {
        id = row["id"]
        name = row["name"]
        root = row["root"]
        let optionsJSON: String = row["options"]
        options = (try? JSONDecoder().decode(ScanOptions.self, from: Data(optionsJSON.utf8))) ?? ScanOptions()
        createdAt = row["createdAt"]
        lastScanAt = row["lastScanAt"]
        lastScanId = row["lastScanId"]
    }
}

/// A source with its document count and total size, for the sidebar.
public struct SourceInfo: Sendable, Hashable, Identifiable {
    public var source: Source
    public var documentCount: Int
    public var totalSize: Int64
    public var lastScan: ScanRecord?

    public var id: Int64 { source.id }
}

public enum ScanStatus: String, Sendable, Codable {
    case running, completed, cancelled, failed
}

public struct ScanRecord: Sendable, Hashable, Identifiable, FetchableRecord {
    public var id: Int64
    public var sourceId: Int64
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: ScanStatus
    public var filesWalked: Int
    public var filesUnchanged: Int
    public var filesParsed: Int
    public var filesDeleted: Int
    public var errors: Int

    public init(row: Row) throws {
        id = row["id"]
        sourceId = row["sourceId"]
        startedAt = row["startedAt"]
        finishedAt = row["finishedAt"]
        status = ScanStatus(rawValue: row["status"]) ?? .failed
        filesWalked = row["filesWalked"]
        filesUnchanged = row["filesUnchanged"]
        filesParsed = row["filesParsed"]
        filesDeleted = row["filesDeleted"]
        errors = row["errors"]
    }
}

/// The columns of a document needed to list it.
public struct DocumentSummary: Sendable, Hashable, Identifiable, FetchableRecord {
    public var id: Int64
    public var sourceId: Int64
    public var parentId: Int64?
    public var path: String
    public var name: String
    public var ext: String
    public var mime: String?
    public var category: MimeCategory
    public var size: Int64
    public var mtime: Int64
    public var title: String?
    public var thumbnailCount: Int

    static let columns = "d.id, d.sourceId, d.parentId, d.path, d.name, d.ext, d.mime, d.category, d.size, d.mtime, d.title, d.thumbnailCount"

    public init(row: Row) throws {
        id = row["id"]
        sourceId = row["sourceId"]
        parentId = row["parentId"]
        path = row["path"]
        name = row["name"]
        ext = row["ext"]
        mime = row["mime"]
        category = MimeCategory(rawValue: row["category"]) ?? .other
        size = row["size"]
        mtime = row["mtime"]
        title = row["title"]
        thumbnailCount = row["thumbnailCount"]
    }

    public var modificationDate: Date { Date(timeIntervalSince1970: TimeInterval(mtime)) }

    /// Archive members have no file of their own
    public var isArchiveMember: Bool { parentId != nil }

    /// The file on disk: the document itself, or the outermost archive holding it
    public var fileSystemPath: String {
        if let range = path.range(of: "#/") {
            return String(path[..<range.lowerBound])
        }
        return path
    }
}

/// Everything known about one document, for the inspector.
public struct DocumentDetail: Sendable, Hashable {
    public var summary: DocumentSummary
    public var content: String?
    public var metadata: [String: MetadataValue]
    public var checksum: String?
    public var error: String?
    public var tags: [String]
    public var scanId: Int64
}

public struct TagCount: Sendable, Hashable, Identifiable {
    public var name: String
    public var count: Int
    public var id: String { name }
}

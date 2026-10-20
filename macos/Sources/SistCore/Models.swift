import Foundation

/// A regular file (or macOS package) found by the walk. `mtime` and `size` are what incremental
/// scans compare against the catalog to decide whether the file has to be parsed again.
public struct FileEntry: Codable, Sendable, Hashable {
    public var path: String
    /// Seconds since 1970
    public var mtime: Int64
    public var size: Int64

    public init(path: String, mtime: Int64, size: Int64) {
        self.path = path
        self.mtime = mtime
        self.size = size
    }
}

/// A metadata value as stored in the catalog's `metadata` JSON column.
public enum MetadataValue: Codable, Sendable, Hashable, CustomStringConvertible {
    case string(String)
    case int(Int64)
    case double(Double)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        }
    }

    public var description: String {
        switch self {
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        }
    }
}

/// Well-known metadata keys, the equivalent of sist2's `enum metakey`.
public enum MetaKey {
    public static let author = "author"
    public static let modifiedBy = "modified_by"
    public static let pages = "pages"
    public static let width = "width"
    public static let height = "height"
    public static let duration = "duration"
    public static let bitrate = "bitrate"
    public static let videoCodec = "video_codec"
    public static let audioCodec = "audio_codec"
    public static let artist = "artist"
    public static let album = "album"
    public static let albumArtist = "album_artist"
    public static let genre = "genre"
    public static let comment = "comment"
    public static let fontName = "font_name"
    public static let fontStyle = "font_style"
    public static let exifMake = "exif_make"
    public static let exifModel = "exif_model"
    public static let exifSoftware = "exif_software"
    public static let exifDateTime = "exif_datetime"
    public static let exifExposureTime = "exif_exposure_time"
    public static let exifFNumber = "exif_fnumber"
    public static let exifFocalLength = "exif_focal_length"
    public static let exifIsoSpeed = "exif_iso"
    public static let exifLens = "exif_lens"
    public static let exifDescription = "exif_description"
    public static let gpsLatitude = "gps_latitude"
    public static let gpsLongitude = "gps_longitude"
    public static let archiveMembers = "archive_members"
}

/// What a parser produces for one file or archive member.
///
/// Archive members get a path of the form `<archive path>#/<member path>` (the same convention as
/// sist2) and carry the archive's path in `parentPath`.
public struct ParsedDocument: Codable, Sendable, Hashable {
    public var path: String
    public var parentPath: String?
    public var name: String
    public var ext: String
    public var mime: String?
    public var size: Int64
    public var mtime: Int64
    public var title: String?
    public var content: String?
    public var metadata: [String: MetadataValue]
    public var checksum: String?
    /// Set when the extractor failed: the document is still indexed by name and path.
    public var error: String?

    public init(
        path: String, parentPath: String? = nil, name: String, ext: String, mime: String?,
        size: Int64, mtime: Int64, title: String? = nil, content: String? = nil,
        metadata: [String: MetadataValue] = [:], checksum: String? = nil, error: String? = nil
    ) {
        self.path = path
        self.parentPath = parentPath
        self.name = name
        self.ext = ext
        self.mime = mime
        self.size = size
        self.mtime = mtime
        self.title = title
        self.content = content
        self.metadata = metadata
        self.checksum = checksum
        self.error = error
    }

    public var category: MimeCategory { MimeCategory(mime: mime) }
}

/// A parsed document plus its thumbnails (JPEG data). Thumbnails travel separately from the JSON
/// part on the worker pipe so they are never base64-encoded.
public struct ParseResult: Sendable {
    public var document: ParsedDocument
    public var thumbnails: [Data]
    /// The full-text columns, prepared ahead of the write so the single writer does not spend
    /// its time rewriting text (see SearchText.indexedText)
    public var indexedText: IndexedText?
    /// The content as the catalog stores it, compressed ahead of the write for the same reason
    /// (see ContentCodec in SistStore). nil when not prepared, or too short to be compressed.
    public var compressedContent: Data?

    public init(document: ParsedDocument, thumbnails: [Data] = []) {
        self.document = document
        self.thumbnails = thumbnails
    }
}

/// The text of a document's full-text index row, already rewritten by SearchText.
public struct IndexedText: Sendable, Hashable {
    public var name: String
    public var title: String?
    public var content: String?
    /// Folders between the source root and the document
    public var path: String
}

/// How archives are handled, as sist2's `--archive` option.
public enum ArchiveMode: String, Codable, Sendable, CaseIterable {
    /// Archives are indexed as plain files
    case skip
    /// The member list becomes the archive's content
    case list
    /// Members are indexed as documents, archives inside archives are not opened
    case shallow
    /// Members are indexed as documents, recursively
    case recurse
}

/// Per-source scan settings. Mirrors the relevant `sist2 scan` options.
public struct ScanOptions: Codable, Sendable, Hashable {
    /// Maximum number of characters of text kept per document (sist2 `--content-size`)
    public var contentSizeLimit: Int = 32_768
    /// 0 disables thumbnails (sist2 `--thumbnail-count`)
    public var thumbnailCount: Int = 1
    /// Longest side in pixels (sist2 `--thumbnail-size`)
    public var thumbnailSize: Int = 552
    /// JPEG quality, 0...1
    public var thumbnailQuality: Double = 0.7
    public var ocrImages: Bool = false
    public var ocrDocuments: Bool = false
    /// Vision language identifiers, in priority order
    public var ocrLanguages: [String] = ["zh-Hans", "en-US"]
    public var archiveMode: ArchiveMode = .recurse
    /// Archive members bigger than this are indexed by name only
    public var maxArchiveMemberSize: Int64 = 256 * 1024 * 1024
    public var computeChecksums: Bool = false
    /// Maximum directory depth below the root, -1 for unlimited (sist2 `--depth`)
    public var maxDepth: Int = -1
    /// Regular expression matched against absolute paths (sist2 `--exclude`)
    public var excludePattern: String? = nil
    public var skipHiddenFiles: Bool = true
    /// Index macOS packages (.app, .rtfd, ...) as single documents instead of descending into them
    public var treatPackagesAsFiles: Bool = true
    /// Only use the file extension to determine the media type (sist2 `--fast`)
    public var fast: Bool = false
    /// Seconds before a parse job is abandoned and its worker killed (sist2 `--job-timeout`)
    public var jobTimeout: Double = 60
    /// Number of parsers running at once, 0 for one per core
    public var threads: Int = 0

    public init() {}

    public var effectiveThreads: Int {
        threads > 0 ? threads : max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Whether files parsed with `other` would come out differently with these options, in which
    /// case unchanged files have to be parsed again. Options that only steer the walk (depth,
    /// exclusions, hidden files, packages) or the scan itself (threads, timeout) need no reparse:
    /// the next walk adds and removes files accordingly. Options added later count as extraction
    /// options until listed here.
    public func changesExtraction(comparedTo other: ScanOptions) -> Bool {
        func extractionOnly(_ options: ScanOptions) -> ScanOptions {
            var copy = options
            let defaults = ScanOptions()
            copy.maxDepth = defaults.maxDepth
            copy.excludePattern = defaults.excludePattern
            copy.skipHiddenFiles = defaults.skipHiddenFiles
            copy.treatPackagesAsFiles = defaults.treatPackagesAsFiles
            copy.jobTimeout = defaults.jobTimeout
            copy.threads = defaults.threads
            return copy
        }
        return extractionOnly(self) != extractionOnly(other)
    }
}

/// Part of a source to scan: a directory, with or without its subdirectories. A scan limited to
/// scopes only adds, updates and deletes documents inside them.
public struct ScanScope: Codable, Sendable, Hashable {
    public var path: String
    public var recursive: Bool

    public init(path: String, recursive: Bool) {
        self.path = path
        self.recursive = recursive
    }
}

public extension String {
    /// The last path component, without going through URL (paths may contain `#/`)
    var lastPathComponentFast: String {
        guard let slash = lastIndex(of: "/") else { return self }
        return String(self[index(after: slash)...])
    }

    /// Lowercased extension of the last path component, without the dot
    var pathExtensionFast: String {
        let name = lastPathComponentFast
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}

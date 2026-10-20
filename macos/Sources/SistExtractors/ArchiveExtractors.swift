import CArchive
import Foundation
import SistCore

public enum ArchiveError: Error, CustomStringConvertible {
    case libarchive(String)

    public var description: String {
        switch self {
        case .libarchive(let message): return message
        }
    }
}

/// One forward pass over the entries of an archive, with libarchive.
final class ArchiveReader {
    struct Entry {
        var path: String
        var isRegularFile: Bool
        var size: Int64?
        var mtime: Int64
        var isEncrypted: Bool
    }

    private let handle: OpaquePointer
    // libarchive reads an in-memory archive in place: the bytes must outlive the handle
    private var memory: UnsafeMutableRawBufferPointer?
    private var entryCount = 0

    /// `raw` reads a compressed stream that is not an archive (notes.txt.gz) as a single entry.
    init(_ input: ExtractionInput, raw: Bool = false) throws {
        let previousLocale = sist_archive_enter_utf8_locale()
        defer { sist_archive_leave_locale(previousLocale) }

        handle = archive_read_new()
        archive_read_support_filter_all(handle)
        if raw {
            archive_read_support_format_raw(handle)
        } else {
            archive_read_support_format_all(handle)
        }

        let status: Int32
        switch input {
        case .file(let path):
            status = archive_read_open_filename(handle, path, 64 * 1024)
        case .data(let data, _):
            let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: max(data.count, 1), alignment: 1)
            data.copyBytes(to: memory)
            self.memory = memory
            status = archive_read_open_memory(handle, memory.baseAddress, data.count)
        }
        guard status == SIST_ARCHIVE_OK else {
            throw ArchiveError.libarchive(errorMessage)
        }
    }

    deinit {
        archive_read_free(handle)
        memory?.deallocate()
    }

    var errorMessage: String {
        archive_error_string(handle).map { String(cString: $0) } ?? "unknown libarchive error"
    }

    /// nil at the end of the archive.
    func next() throws -> Entry? {
        let previousLocale = sist_archive_enter_utf8_locale()
        defer { sist_archive_leave_locale(previousLocale) }

        var entry: OpaquePointer?
        let status = archive_read_next_header(handle, &entry)
        if status == SIST_ARCHIVE_EOF {
            return nil
        }
        guard status != SIST_ARCHIVE_FATAL, let entry else {
            throw ArchiveError.libarchive(errorMessage)
        }
        entryCount += 1

        let type = UInt32(archive_entry_filetype(entry)) & UInt32(SIST_AE_IFMT)
        return Entry(
            path: Self.path(of: entry) ?? "entry-\(entryCount)",
            isRegularFile: type == UInt32(SIST_AE_IFREG),
            size: archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil,
            mtime: Int64(archive_entry_mtime(entry)),
            isEncrypted: archive_entry_is_encrypted(entry) > 0)
    }

    /// The current entry's data, or nil when it is bigger than `limit` (it is then skipped).
    func readData(limit: Int64) throws -> Data? {
        let previousLocale = sist_archive_enter_utf8_locale()
        defer { sist_archive_leave_locale(previousLocale) }

        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { archive_read_data(handle, $0.baseAddress, $0.count) }
            if count == 0 {
                return data
            }
            if count < 0 {
                throw ArchiveError.libarchive(errorMessage)
            }
            if Int64(data.count + count) > limit {
                archive_read_data_skip(handle)
                return nil
            }
            data.append(chunk, count: count)
        }
    }

    /// Entry names: the raw form when it is UTF-8 (tar, and anything once the locale is UTF-8),
    /// the converted UTF-8 form otherwise, and the raw bytes decoded as legacy text last (zip
    /// written by Windows in a Chinese locale, without its UTF-8 flag).
    static func path(of entry: OpaquePointer) -> String? {
        func bytes(_ string: UnsafePointer<CChar>) -> [UInt8] {
            Array(UnsafeBufferPointer(start: UnsafeRawPointer(string).assumingMemoryBound(to: UInt8.self),
                                      count: strlen(string)))
        }
        let raw = archive_entry_pathname(entry).map(bytes)
        if let raw, TextDecoding.isValidUTF8(raw[...]) {
            return String(decoding: raw, as: UTF8.self)
        }
        if let utf8 = archive_entry_pathname_utf8(entry).map(bytes), TextDecoding.isValidUTF8(utf8[...]) {
            return String(decoding: utf8, as: UTF8.self)
        }
        return raw.map(TextDecoding.decodeName)
    }
}

/// Archives through libarchive, as sist2 does: tar (with gzip, bzip2, xz, zstd...), 7z, rar,
/// zip, iso, cab. Members become documents of their own, recursively. A compressed file that is
/// not an archive (report.txt.gz) is indexed through its single decompressed member.
public struct ArchiveExtractor: Extractor {
    public init() {}

    static let mimes: Set<String> = [
        "application/zip", "application/java-archive", "application/x-tar", "application/gzip",
        "application/x-bzip2", "application/x-xz", "application/zstd", "application/x-7z-compressed",
        "application/vnd.rar", "application/x-iso9660-image", "application/vnd.ms-cab-compressed",
        "application/x-xar", "application/x-cpio",
    ]
    /// Compression without an archive format: read as a single compressed file when libarchive
    /// finds no archive inside
    static let streamMimes: Set<String> = ["application/gzip", "application/x-bzip2", "application/x-xz",
                                           "application/zstd"]

    static func isCompressedStream(_ input: ExtractionInput) -> Bool {
        guard let header = try? input.read(limit: 512), let mime = MimeTypes.sniff(header) else { return false }
        return streamMimes.contains(mime)
    }

    public func accepts(mime: String, ext: String) -> Bool {
        Self.mimes.contains(mime)
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        var reader: ArchiveReader
        var first: ArchiveReader.Entry?
        do {
            reader = try ArchiveReader(input)
            first = try reader.next()
        } catch where Self.isCompressedStream(input) {
            // "Unrecognized archive format": a plain compressed file
            reader = try ArchiveReader(input, raw: true)
            first = try reader.next()
            first?.path = Self.decompressedName(input.name)
        }

        let options = context.options
        var members: Int64 = 0
        var entry = first
        while let current = entry {
            defer { entry = Self.nextEntry(reader, context: context) }
            guard current.isRegularFile else { continue }
            members += 1

            switch options.archiveMode {
            case .skip:
                return
            case .list:
                result.content.appendLine(current.path)
            case .shallow, .recurse:
                var data: Data?
                if current.isEncrypted {
                    context.log(.info, "Encrypted member, indexed by name: \(current.path)")
                } else {
                    do {
                        data = try reader.readData(limit: options.maxArchiveMemberSize)
                    } catch {
                        context.log(.warning, "Could not extract \(current.path): \(error)")
                    }
                }
                context.parseMember(ArchiveMember(path: current.path, data: data, mtime: current.mtime,
                                                  size: current.size ?? Int64(data?.count ?? 0)))
            }
        }
        result.metadata[MetaKey.archiveMembers] = .int(members)
    }

    /// A broken entry ends the walk but keeps the members read so far
    static func nextEntry(_ reader: ArchiveReader, context: ExtractionContext) -> ArchiveReader.Entry? {
        do {
            return try reader.next()
        } catch {
            context.log(.warning, "Archive read stopped: \(error)")
            return nil
        }
    }

    /// report.txt.gz -> report.txt, logs.tgz -> logs.tar
    static func decompressedName(_ name: String) -> String {
        let lower = name.lowercased()
        for (suffix, replacement) in [(".tgz", ".tar"), (".tbz2", ".tar"), (".tbz", ".tar"), (".txz", ".tar"),
                                      (".gz", ""), (".bz2", ""), (".xz", ""), (".zst", "")] where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count)) + replacement
        }
        return name + ".out"
    }
}

/// Comic book archives (.cbz, .cbr): the first page, by name, as thumbnail. Pages are not indexed.
public struct ComicBookExtractor: Extractor {
    public init() {}

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "avif", "heic"]

    public func accepts(mime: String, ext: String) -> Bool {
        mime == "application/x-cbz" || mime == "application/x-cbr"
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        // Two passes: names first (pages are rarely stored in order), then the first page
        var pages: [String] = []
        let listing = try ArchiveReader(input)
        while let entry = try listing.next() {
            if entry.isRegularFile && Self.imageExtensions.contains(entry.path.pathExtensionFast) {
                pages.append(entry.path)
            }
        }
        result.metadata[MetaKey.pages] = .int(Int64(pages.count))

        guard context.options.thumbnailCount > 0,
              let cover = pages.min(by: { $0.localizedStandardCompare($1) == .orderedAscending }) else { return }
        let reader = try ArchiveReader(input)
        var found = false
        while let entry = try reader.next() {
            if entry.path == cover {
                found = true
                break
            }
        }
        if found, let data = try reader.readData(limit: 64 * 1024 * 1024),
           let thumbnail = ImageScaling.thumbnail(from: data, options: context.options) {
            result.thumbnails.append(thumbnail)
        }
    }
}

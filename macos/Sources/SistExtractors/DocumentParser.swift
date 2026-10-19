import Foundation
import SistCore
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Parses one file into documents: media type detection, the matching extractor, archive
/// members, checksum and thumbnail. This is what a `sist-worker` process runs for each job, and
/// what the in-process pool runs directly (sist2's parse.c).
public final class DocumentParser: Sendable {
    public let options: ScanOptions
    private let extractors: [any Extractor]
    private let logHandler: LogHandler?
    #if canImport(QuickLookThumbnailing)
    private let quickLook = QuickLookThumbnailer()
    #endif

    /// Archives nested deeper than this are indexed as plain files
    public static let maxArchiveDepth = 8

    public init(options: ScanOptions, log: LogHandler? = nil) {
        self.options = options
        self.logHandler = log

        // First match wins
        var extractors: [any Extractor] = []
        #if canImport(PDFKit)
        extractors.append(PDFExtractor())
        #endif
        extractors += [OOXMLExtractor(), EPUBExtractor(), ZipArchiveExtractor()]
        #if canImport(ImageIO)
        extractors.append(ImageExtractor())
        #endif
        #if canImport(AVFoundation)
        extractors.append(MediaExtractor())
        #endif
        #if canImport(CoreText)
        extractors.append(FontExtractor())
        #endif
        #if canImport(AppKit)
        extractors.append(RichTextExtractor())
        #endif
        extractors += [MarkupExtractor(), JSONExtractor(), PlainTextExtractor()]
        self.extractors = extractors
    }

    /// Calls `emit` for the file, and for each archive member after its archive. An archive is
    /// emitted twice: once before its first member so the member can reference it, then complete.
    public func parse(_ entry: FileEntry, emit: (ParseResult) -> Void) {
        parse(input: .file(path: entry.path), path: entry.path, parentPath: nil,
              mtime: entry.mtime, size: entry.size, depth: 0, emit: emit)
    }

    func parse(input: ExtractionInput?, path: String, parentPath: String?, mtime: Int64, size: Int64,
               depth: Int, emit: (ParseResult) -> Void) {
        let name = path.lastPathComponentFast
        let ext = name.pathExtensionFast
        var isDirectory = false
        if case .file(let filePath) = input, size == 0 {
            var flag: ObjCBool = false
            isDirectory = FileManager.default.fileExists(atPath: filePath, isDirectory: &flag) && flag.boolValue
        }

        var document = ParsedDocument(path: path, parentPath: parentPath, name: name, ext: ext,
                                      mime: detectMime(input, ext: ext, size: size, isDirectory: isDirectory),
                                      size: size, mtime: mtime)
        var extracted = Extracted(contentLimit: options.contentSizeLimit)

        if let input, !isDirectory || document.mime == "text/rtf",
           let mime = document.mime, let extractor = extractor(for: mime, ext: ext, depth: depth) {
            var archiveEmitted = false
            withoutActuallyEscaping(emit) { emit in
                let context = ExtractionContext(
                    options: options, path: path, depth: depth,
                    logHandler: { [logHandler] level, path, message in
                        logHandler?(LogMessage(level: level, path: path, message: message))
                    },
                    memberHandler: { member in
                        if !archiveEmitted {
                            emit(ParseResult(document: document))
                            archiveEmitted = true
                        }
                        self.parse(input: member.data.map { .data($0, name: member.path.lastPathComponentFast) },
                                   path: path + "#/" + member.path, parentPath: path,
                                   mtime: member.mtime, size: member.size, depth: depth + 1, emit: emit)
                    })
                do {
                    try extractor.extract(input, into: &extracted, context: context)
                } catch {
                    document.error = String(describing: error)
                    log(.warning, path, "\(type(of: extractor)): \(error)")
                }
            }
        }

        document.title = extracted.title
        document.content = extracted.content.text.isEmpty ? nil : extracted.content.text
        document.metadata = extracted.metadata

        var thumbnails = Array(extracted.thumbnails.prefix(options.thumbnailCount))
        #if canImport(QuickLookThumbnailing)
        let quickLookCategories: Set<MimeCategory> = [.document, .image, .video, .font, .application]
        if thumbnails.isEmpty, options.thumbnailCount > 0, case .file(let filePath) = input,
           quickLookCategories.contains(document.category) || isDirectory,
           let thumbnail = quickLook.thumbnail(path: filePath, options: options,
                                               icon: document.category == .application || isDirectory) {
            thumbnails.append(thumbnail)
        }
        #endif

        if options.computeChecksums, !isDirectory, let input {
            document.checksum = Self.sha1(input)
        }

        emit(ParseResult(document: document, thumbnails: thumbnails))
    }

    func extractor(for mime: String, ext: String, depth: Int) -> (any Extractor)? {
        guard let extractor = extractors.first(where: { $0.accepts(mime: mime, ext: ext) }) else { return nil }
        if extractor is ZipArchiveExtractor {
            if options.archiveMode == .skip { return nil }
            if depth > 0 && options.archiveMode == .shallow { return nil }
            if depth >= Self.maxArchiveDepth { return nil }
        }
        return extractor
    }

    /// Extension first, as sist2 does; then UTType; then the leading bytes, unless `fast`.
    func detectMime(_ input: ExtractionInput?, ext: String, size: Int64, isDirectory: Bool) -> String? {
        if !ext.isEmpty, let mime = MimeTypes.mime(forExtension: ext) {
            return mime
        }
        #if canImport(UniformTypeIdentifiers)
        if !ext.isEmpty, let mime = UTType(filenameExtension: ext)?.preferredMIMEType {
            return mime
        }
        #endif
        if isDirectory { return nil }
        if size == 0 { return "application/x-empty" }
        if options.fast { return nil }
        guard let input, let header = try? input.read(limit: 512) else { return nil }
        return MimeTypes.sniff(header) ?? "application/octet-stream"
    }

    func log(_ level: LogLevel, _ path: String, _ message: String) {
        logHandler?(LogMessage(level: level, path: path, message: message))
    }

    static func sha1(_ input: ExtractionInput) -> String? {
        #if canImport(CryptoKit)
        var hasher = Insecure.SHA1()
        switch input {
        case .data(let data, _):
            hasher.update(data: data)
        case .file(let path):
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}

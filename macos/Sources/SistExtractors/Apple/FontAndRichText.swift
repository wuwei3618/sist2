import Foundation
import SistCore
#if canImport(CoreText)
import CoreText
#endif
#if canImport(AppKit)
import AppKit
#endif

#if canImport(CoreText)
/// Fonts with CoreText, replacing FreeType: family and style names. The thumbnail comes from
/// QuickLook, which renders a sample of the font.
public struct FontExtractor: Extractor {
    public init() {}

    public func accepts(mime: String, ext: String) -> Bool {
        mime.hasPrefix("font/") || mime == "application/x-dfont"
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        let names: [(family: String?, style: String?, display: String?)] = try input.withFileURL { url in
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  !descriptors.isEmpty else {
                throw ExtractionError.invalidFormat("CoreText cannot read this font")
            }
            return descriptors.map {
                (family: CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String,
                 style: CTFontDescriptorCopyAttribute($0, kCTFontStyleNameAttribute) as? String,
                 display: CTFontDescriptorCopyAttribute($0, kCTFontDisplayNameAttribute) as? String)
            }
        }
        result.title = names[0].display ?? names[0].family
        result.setMetadata(MetaKey.fontName, names[0].family)
        result.setMetadata(MetaKey.fontStyle, names[0].style)
        // A collection (.ttc) holds several faces: all their names are searchable
        for name in names {
            result.content.appendLine([name.display, name.family, name.style].compactMap { $0 }.joined(separator: " "))
        }
    }
}
#endif

#if canImport(AppKit)
/// RTF, RTFD, Word 97-2003 (.doc) and OpenDocument text through AppKit's text importers,
/// replacing antiword. Word .docx is handled by OOXMLExtractor, which is faster.
public struct RichTextExtractor: Extractor {
    public init() {}

    static let mimes: Set<String> = ["text/rtf", "application/rtf", "application/msword",
                                     "application/vnd.oasis.opendocument.text"]

    public func accepts(mime: String, ext: String) -> Bool {
        Self.mimes.contains(mime)
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        let (text, title, author): (String, String?, String?) = try input.withFileURL { url in
            var attributes: NSDictionary?
            let string = try NSAttributedString(url: url, options: [:], documentAttributes: &attributes)
            return (string.string,
                    attributes?[NSAttributedString.DocumentAttributeKey.title] as? String,
                    attributes?[NSAttributedString.DocumentAttributeKey.author] as? String)
        }
        result.title = title?.isEmpty == false ? title : nil
        result.setMetadata(MetaKey.author, author)
        result.content.append(text)
    }
}
#endif

#if canImport(QuickLookThumbnailing)
import QuickLookThumbnailing

/// QuickLook thumbnails for whatever the extractors did not cover: Office, iWork, fonts,
/// videos AVFoundation cannot open, application icons... Every QuickLook extension installed on
/// the Mac extends what gets a thumbnail.
public struct QuickLookThumbnailer: Sendable {
    public init() {}

    public func thumbnail(path: String, options: ScanOptions, icon: Bool) -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: options.thumbnailSize, height: options.thumbnailSize),
            scale: 1,
            representationTypes: icon ? [.icon, .thumbnail] : .thumbnail)
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedBox<Data?>(nil)
        let quality = options.thumbnailQuality
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            if let image = representation?.cgImage {
                box.value = ImageScaling.encode(image, quality: quality)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            QLThumbnailGenerator.shared.cancel(request)
            return nil
        }
        return box.value
    }
}
#endif

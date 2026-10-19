#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import SistCore

/// Images, including camera RAW, with ImageIO (replacing ffmpeg/LibRaw/libexif): dimensions,
/// EXIF, TIFF and GPS metadata, a thumbnail, and OCR with Vision when enabled.
public struct ImageExtractor: Extractor {
    public init() {}

    static let excluded: Set<String> = ["image/svg+xml", "image/vnd.djvu"]

    public func accepts(mime: String, ext: String) -> Bool {
        mime.hasPrefix("image/") && !Self.excluded.contains(mime)
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        let source: CGImageSource?
        switch input {
        case .file(let path): source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        case .data(let data, _): source = CGImageSourceCreateWithData(data as CFData, nil)
        }
        guard let source, CGImageSourceGetCount(source) > 0 else {
            throw ExtractionError.invalidFormat("ImageIO cannot decode this image")
        }

        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            Self.readProperties(properties, into: &result)
        }

        let options = context.options
        if options.thumbnailCount > 0, let thumbnail = ImageScaling.thumbnail(from: source, options: options) {
            result.thumbnails.append(thumbnail)
        }

        if options.ocrImages, let image = ImageScaling.downscaled(source, maxPixelSize: 4096) {
            do {
                result.content.append(try VisionOCR.recognizeText(in: image, languages: options.ocrLanguages))
            } catch {
                context.log(.warning, "OCR failed: \(error)")
            }
        }
    }

    static func readProperties(_ properties: [CFString: Any], into result: inout Extracted) {
        if let width = properties[kCGImagePropertyPixelWidth] as? Int {
            result.metadata[MetaKey.width] = .int(Int64(width))
        }
        if let height = properties[kCGImagePropertyPixelHeight] as? Int {
            result.metadata[MetaKey.height] = .int(Int64(height))
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            result.setMetadata(MetaKey.exifMake, tiff[kCGImagePropertyTIFFMake] as? String)
            result.setMetadata(MetaKey.exifModel, tiff[kCGImagePropertyTIFFModel] as? String)
            result.setMetadata(MetaKey.exifSoftware, tiff[kCGImagePropertyTIFFSoftware] as? String)
            result.setMetadata(MetaKey.exifDescription, tiff[kCGImagePropertyTIFFImageDescription] as? String)
            result.setMetadata(MetaKey.author, tiff[kCGImagePropertyTIFFArtist] as? String)
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            result.setMetadata(MetaKey.exifDateTime, exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            result.setMetadata(MetaKey.exifLens, exif[kCGImagePropertyExifLensModel] as? String)
            if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
                result.setMetadata(MetaKey.exifExposureTime,
                                   exposure < 1 ? "1/\(Int((1 / exposure).rounded()))" : String(format: "%.1f", exposure))
            }
            if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
                result.setMetadata(MetaKey.exifFNumber, String(format: "f/%.1f", fNumber))
            }
            if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
                result.setMetadata(MetaKey.exifFocalLength, String(format: "%.0f mm", focal))
            }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
                result.metadata[MetaKey.exifIsoSpeed] = .int(Int64(iso))
            }
            if let comment = exif[kCGImagePropertyExifUserComment] as? String {
                result.content.append(comment)
            }
        }

        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            let north = (gps[kCGImagePropertyGPSLatitudeRef] as? String) != "S"
            let east = (gps[kCGImagePropertyGPSLongitudeRef] as? String) != "W"
            result.metadata[MetaKey.gpsLatitude] = .double(north ? latitude : -latitude)
            result.metadata[MetaKey.gpsLongitude] = .double(east ? longitude : -longitude)
        }

        if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            if let title = iptc[kCGImagePropertyIPTCObjectName] as? String, !title.isEmpty {
                result.title = title
            }
            if let caption = iptc[kCGImagePropertyIPTCCaptionAbstract] as? String {
                result.content.append(caption)
            }
            if let keywords = iptc[kCGImagePropertyIPTCKeywords] as? [String] {
                result.content.append(keywords.joined(separator: " "))
            }
        }
    }
}
#endif

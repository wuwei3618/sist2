import Foundation
import SistCore
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Thumbnail encoding. On platforms without ImageIO there are no thumbnails.
public enum ImageScaling {
    /// A thumbnail no larger than `options.thumbnailSize` on its longest side, or nil when the
    /// data is not an image this platform can decode.
    public static func thumbnail(from data: Data, options: ScanOptions) -> Data? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source, options: options)
        #else
        return nil
        #endif
    }

    #if canImport(ImageIO)
    public static func thumbnail(from source: CGImageSource, options: ScanOptions) -> Data? {
        guard let image = downscaled(source, maxPixelSize: options.thumbnailSize) else { return nil }
        return encode(image, quality: options.thumbnailQuality)
    }

    /// Decodes the first image of `source` at no more than `maxPixelSize`, honouring EXIF orientation.
    public static func downscaled(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let parameters: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, parameters as CFDictionary)
    }

    /// JPEG, or PNG when the image has transparency (JPEG would turn it black).
    public static func encode(_ image: CGImage, quality: Double) -> Data? {
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Scales `image` down so that its longest side is at most `maxPixelSize`.
    public static func fit(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixelSize else { return image }
        let scale = Double(maxPixelSize) / Double(longest)
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
    #endif
}

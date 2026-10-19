#if canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import Foundation
import SistCore

/// Audio and video with AVFoundation, replacing ffmpeg: duration, codecs, dimensions, bitrate,
/// common tags (title, artist, album...), a video frame or the embedded cover as thumbnail.
///
/// AVFoundation does not open Matroska, AVI or WMV; those files are indexed by name and get a
/// QuickLook thumbnail when a QuickLook extension handles them.
public struct MediaExtractor: Extractor {
    public init() {}

    public func accepts(mime: String, ext: String) -> Bool {
        mime.hasPrefix("audio/") || mime.hasPrefix("video/")
    }

    struct MediaInfo: Sendable {
        var duration: Double?
        var tags: [String: String] = [:]
        var title: String?
        var comment: String?
        var width: Int?
        var height: Int?
        var videoCodec: String?
        var audioCodec: String?
        var bitrate: Int?
        var thumbnail: Data?
    }

    public func extract(_ input: ExtractionInput, into result: inout Extracted, context: ExtractionContext) throws {
        let options = context.options
        let info = try input.withFileURL { url in
            try runBlocking(timeout: max(10, options.jobTimeout - 5)) {
                try await Self.load(url: url, options: options)
            }
        }

        result.title = info.title
        if let duration = info.duration {
            result.metadata[MetaKey.duration] = .double((duration * 10).rounded() / 10)
        }
        if let width = info.width, let height = info.height {
            result.metadata[MetaKey.width] = .int(Int64(width))
            result.metadata[MetaKey.height] = .int(Int64(height))
        }
        if let bitrate = info.bitrate {
            result.metadata[MetaKey.bitrate] = .int(Int64(bitrate))
        }
        result.setMetadata(MetaKey.videoCodec, info.videoCodec)
        result.setMetadata(MetaKey.audioCodec, info.audioCodec)
        for (key, value) in info.tags {
            result.setMetadata(key, value)
        }
        if let comment = info.comment {
            result.content.append(comment)
        }
        if let thumbnail = info.thumbnail {
            result.thumbnails.append(thumbnail)
        }
    }

    static func load(url: URL, options: ScanOptions) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let (duration, metadata, tracks) = try await asset.load(.duration, .commonMetadata, .tracks)

        var info = MediaInfo()
        if duration.isNumeric {
            info.duration = duration.seconds
        }

        var artwork: Data?
        for item in metadata {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                info.title = try? await item.load(.stringValue)
            case .commonKeyArtist:
                info.tags[MetaKey.artist] = try? await item.load(.stringValue)
            case .commonKeyAlbumName:
                info.tags[MetaKey.album] = try? await item.load(.stringValue)
            case .commonKeyCreator, .commonKeyAuthor:
                info.tags[MetaKey.author] = try? await item.load(.stringValue)
            case .commonKeyDescription:
                info.comment = try? await item.load(.stringValue)
            case .commonKeyArtwork:
                artwork = try? await item.load(.dataValue)
            default:
                break
            }
        }

        var totalBitrate: Float = 0
        var hasVideo = false
        for track in tracks {
            // mediaType is a plain property, not one of the asynchronously loaded ones
            let mediaType = track.mediaType
            let (formats, rate) = try await track.load(.formatDescriptions, .estimatedDataRate)
            totalBitrate += rate
            let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
            if mediaType == .video {
                hasVideo = true
                let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                let oriented = size.applying(transform)
                info.width = Int(abs(oriented.width))
                info.height = Int(abs(oriented.height))
                info.videoCodec = codec
            } else if mediaType == .audio {
                info.audioCodec = codec
            }
        }
        if totalBitrate > 0 {
            info.bitrate = Int(totalBitrate)
        }

        if options.thumbnailCount > 0 {
            if hasVideo {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: options.thumbnailSize, height: options.thumbnailSize)
                // A frame a little into the video: the first one is often black
                let seconds = min(max((info.duration ?? 0) * 0.1, 0), 30)
                if let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                    info.thumbnail = ImageScaling.encode(frame.image, quality: options.thumbnailQuality)
                }
            } else if let artwork {
                info.thumbnail = ImageScaling.thumbnail(from: artwork, options: options)
            }
        }
        return info
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
#endif

import AppKit
import SwiftUI
import SistCore
import SistStore

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func number(_ value: Int) -> String {
        value.formatted(.number)
    }
}

extension MimeCategory {
    var displayName: String {
        switch self {
        case .text: return "文本"
        case .document: return "文档"
        case .image: return "图片"
        case .audio: return "音频"
        case .video: return "视频"
        case .archive: return "压缩包"
        case .font: return "字体"
        case .email: return "邮件"
        case .application: return "应用程序"
        case .other: return "其他"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "doc.plaintext"
        case .document: return "doc.richtext"
        case .image: return "photo"
        case .audio: return "music.note"
        case .video: return "film"
        case .archive: return "archivebox"
        case .font: return "textformat"
        case .email: return "envelope"
        case .application: return "app"
        case .other: return "doc"
        }
    }
}

extension ArchiveMode {
    var displayName: String {
        switch self {
        case .skip: return "不处理"
        case .list: return "只索引文件列表"
        case .shallow: return "索引成员（不递归）"
        case .recurse: return "索引成员（递归）"
        }
    }
}

extension SearchSort {
    var displayName: String {
        switch self {
        case .relevance: return "相关度"
        case .modifiedNewest: return "修改时间（新→旧）"
        case .modifiedOldest: return "修改时间（旧→新）"
        case .sizeLargest: return "大小（大→小）"
        case .sizeSmallest: return "大小（小→大）"
        case .name: return "名称"
        }
    }
}

enum MetadataLabel {
    static let names: [String: String] = [
        MetaKey.author: "作者", MetaKey.modifiedBy: "最后修改者", MetaKey.pages: "页数",
        MetaKey.width: "宽度", MetaKey.height: "高度", MetaKey.duration: "时长（秒）",
        MetaKey.bitrate: "码率", MetaKey.videoCodec: "视频编码", MetaKey.audioCodec: "音频编码",
        MetaKey.artist: "艺术家", MetaKey.album: "专辑", MetaKey.albumArtist: "专辑艺术家",
        MetaKey.genre: "流派", MetaKey.comment: "注释", MetaKey.fontName: "字体",
        MetaKey.fontStyle: "字重/样式", MetaKey.exifMake: "相机厂商", MetaKey.exifModel: "相机型号",
        MetaKey.exifSoftware: "软件", MetaKey.exifDateTime: "拍摄时间", MetaKey.exifExposureTime: "曝光时间",
        MetaKey.exifFNumber: "光圈", MetaKey.exifFocalLength: "焦距", MetaKey.exifIsoSpeed: "ISO",
        MetaKey.exifLens: "镜头", MetaKey.exifDescription: "描述", MetaKey.gpsLatitude: "纬度",
        MetaKey.gpsLongitude: "经度", MetaKey.archiveMembers: "成员数", MetaKey.publisher: "出版社",
        MetaKey.keywords: "关键词", MetaKey.language: "语言", MetaKey.emailFrom: "发件人", MetaKey.emailTo: "收件人",
        MetaKey.emailCc: "抄送", MetaKey.emailDate: "发送时间", MetaKey.imageLabels: "图片内容",
    ]

    static func name(for key: String) -> String {
        names[key] ?? key
    }
}

extension Snippet {
    /// Matches in bold on a yellow background
    var attributed: AttributedString {
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            if segment.highlighted {
                part.inlinePresentationIntent = .stronglyEmphasized
                part.backgroundColor = Color.yellow.opacity(0.35)
            }
            result += part
        }
        return result
    }
}

extension DocumentSummary {
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return name
    }

    /// The folder holding the document, or the archive path for members
    var location: String {
        if let range = path.range(of: "#/", options: .backwards) {
            return String(path[..<range.lowerBound])
        }
        return (path as NSString).deletingLastPathComponent
    }

    var fileURL: URL { URL(fileURLWithPath: fileSystemPath) }

    @MainActor func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @MainActor func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

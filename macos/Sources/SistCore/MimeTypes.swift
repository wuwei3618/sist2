import Foundation

/// Coarse kind of a document, used for the sidebar facets and to pick a thumbnail strategy.
public enum MimeCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case text
    case document
    case image
    case audio
    case video
    case archive
    case font
    case email
    case application
    case other

    public init(mime: String?) {
        guard let mime else {
            self = .other
            return
        }
        if let special = MimeTypes.categoryOverrides[mime] {
            self = special
            return
        }
        switch mime.split(separator: "/").first {
        case "text": self = .text
        case "image": self = .image
        case "audio": self = .audio
        case "video": self = .video
        case "font": self = .font
        case "message": self = .email
        default: self = .other
        }
    }
}

public enum MimeTypes {
    /// Extension (lowercase, no dot) to media type. Covers what the extractors handle plus the
    /// common types worth a facet; anything else falls back to UTType on macOS and sniffing.
    public static let byExtension: [String: String] = [
        // Text & code
        "txt": "text/plain", "text": "text/plain", "log": "text/plain", "md": "text/markdown",
        "markdown": "text/markdown", "csv": "text/csv", "tsv": "text/tab-separated-values",
        "ini": "text/plain", "cfg": "text/plain", "conf": "text/plain", "yaml": "text/yaml",
        "yml": "text/yaml", "toml": "text/plain", "srt": "text/plain", "vtt": "text/vtt",
        "tex": "text/x-tex", "rst": "text/plain", "org": "text/plain",
        "c": "text/x-c", "h": "text/x-c", "cpp": "text/x-c++", "cc": "text/x-c++", "hpp": "text/x-c++",
        "m": "text/x-objc", "mm": "text/x-objc", "swift": "text/x-swift", "java": "text/x-java",
        "kt": "text/x-kotlin", "go": "text/x-go", "rs": "text/x-rust", "py": "text/x-python",
        "rb": "text/x-ruby", "php": "text/x-php", "pl": "text/x-perl", "lua": "text/x-lua",
        "js": "text/javascript", "mjs": "text/javascript", "ts": "text/x-typescript",
        "tsx": "text/x-typescript", "jsx": "text/javascript", "css": "text/css", "scss": "text/x-scss",
        "sh": "text/x-shellscript", "bash": "text/x-shellscript", "zsh": "text/x-shellscript",
        "sql": "text/x-sql", "r": "text/x-r", "scala": "text/x-scala", "cs": "text/x-csharp",
        "vue": "text/plain", "gradle": "text/plain", "properties": "text/plain",
        // Markup & data
        "html": "text/html", "htm": "text/html", "xhtml": "application/xhtml+xml",
        "xml": "text/xml", "svg": "image/svg+xml", "plist": "application/x-plist",
        "json": "application/json", "jsonl": "application/x-ndjson", "ndjson": "application/x-ndjson",
        "rtf": "text/rtf", "rtfd": "text/rtf",
        "webarchive": "application/x-webarchive",
        // Documents
        "pdf": "application/pdf",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "dotx": "application/vnd.openxmlformats-officedocument.wordprocessingml.template",
        "xls": "application/vnd.ms-excel", "xlt": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint", "pps": "application/vnd.ms-powerpoint",
        "pot": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "odt": "application/vnd.oasis.opendocument.text",
        "ods": "application/vnd.oasis.opendocument.spreadsheet",
        "odp": "application/vnd.oasis.opendocument.presentation",
        "pages": "application/x-iwork-pages-sffpages",
        "numbers": "application/x-iwork-numbers-sffnumbers",
        "key": "application/x-iwork-keynote-sffkey",
        "epub": "application/epub+zip",
        "mobi": "application/x-mobipocket-ebook", "azw3": "application/vnd.amazon.ebook",
        "fb2": "application/x-fictionbook+xml", "djvu": "image/vnd.djvu", "xps": "application/oxps",
        "cbz": "application/x-cbz", "cbr": "application/x-cbr",
        // Images
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif",
        "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff", "webp": "image/webp",
        "heic": "image/heic", "heif": "image/heif", "avif": "image/avif", "ico": "image/x-icon",
        "icns": "image/x-icns", "psd": "image/vnd.adobe.photoshop", "jxl": "image/jxl",
        "dng": "image/x-adobe-dng", "cr2": "image/x-canon-cr2", "cr3": "image/x-canon-cr3",
        "crw": "image/x-canon-crw", "nef": "image/x-nikon-nef", "nrw": "image/x-nikon-nrw",
        "arw": "image/x-sony-arw", "sr2": "image/x-sony-sr2", "srf": "image/x-sony-srf",
        "orf": "image/x-olympus-orf", "rw2": "image/x-panasonic-rw2", "raf": "image/x-fuji-raf",
        "pef": "image/x-pentax-pef", "erf": "image/x-epson-erf", "kdc": "image/x-kodak-kdc",
        "dcr": "image/x-kodak-dcr", "mrw": "image/x-minolta-mrw", "3fr": "image/x-hasselblad-3fr",
        "srw": "image/x-samsung-srw",
        // Audio
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "flac": "audio/flac",
        "wav": "audio/wav", "aiff": "audio/aiff", "aif": "audio/aiff", "ogg": "audio/ogg",
        "opus": "audio/opus", "wma": "audio/x-ms-wma", "caf": "audio/x-caf",
        "mid": "audio/midi", "midi": "audio/midi", "ape": "audio/x-ape",
        // Video
        "mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime", "mkv": "video/x-matroska",
        "webm": "video/webm", "avi": "video/x-msvideo", "wmv": "video/x-ms-wmv", "flv": "video/x-flv",
        "mpg": "video/mpeg", "mpeg": "video/mpeg", "3gp": "video/3gpp",
        "m2ts": "video/mp2t", "mts": "video/mp2t",
        // Archives
        "zip": "application/zip", "jar": "application/java-archive", "7z": "application/x-7z-compressed",
        "rar": "application/vnd.rar", "tar": "application/x-tar", "gz": "application/gzip",
        "tgz": "application/gzip", "bz2": "application/x-bzip2", "xz": "application/x-xz",
        "zst": "application/zstd", "dmg": "application/x-apple-diskimage", "iso": "application/x-iso9660-image",
        "pkg": "application/x-xar", "tbz2": "application/x-bzip2", "tbz": "application/x-bzip2",
        "txz": "application/x-xz", "cab": "application/vnd.ms-cab-compressed", "cpio": "application/x-cpio",
        // Fonts
        "ttf": "font/ttf", "otf": "font/otf", "ttc": "font/collection", "woff": "font/woff",
        "woff2": "font/woff2", "dfont": "application/x-dfont",
        // Email
        "eml": "message/rfc822", "emlx": "message/rfc822", "mbox": "application/mbox",
        "msg": "application/vnd.ms-outlook", "pst": "application/vnd.ms-outlook-pst",
        // Applications
        "app": "application/x-apple-application", "exe": "application/x-msdownload",
        "dll": "application/x-msdownload", "dylib": "application/x-mach-binary",
        "so": "application/x-sharedlib", "apk": "application/vnd.android.package-archive",
    ]

    /// Media types whose major type does not say what they are
    static let categoryOverrides: [String: MimeCategory] = {
        var map: [String: MimeCategory] = [:]
        for mime in [
            "application/pdf", "application/msword", "application/vnd.ms-excel", "application/vnd.ms-powerpoint",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.template",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.oasis.opendocument.text", "application/vnd.oasis.opendocument.spreadsheet",
            "application/vnd.oasis.opendocument.presentation", "application/x-iwork-pages-sffpages",
            "application/x-iwork-numbers-sffnumbers", "application/x-iwork-keynote-sffkey",
            "application/epub+zip", "application/x-mobipocket-ebook", "application/vnd.amazon.ebook",
            "application/x-fictionbook+xml", "image/vnd.djvu", "application/oxps", "application/x-cbz",
            "application/x-cbr", "text/rtf", "application/x-webarchive",
        ] {
            map[mime] = .document
        }
        for mime in [
            "application/zip", "application/java-archive", "application/x-7z-compressed", "application/vnd.rar",
            "application/x-tar", "application/gzip", "application/x-bzip2", "application/x-xz", "application/zstd",
            "application/x-apple-diskimage", "application/x-iso9660-image", "application/x-xar",
            "application/vnd.ms-cab-compressed", "application/x-cpio",
        ] {
            map[mime] = .archive
        }
        for mime in ["application/json", "application/x-ndjson", "application/xhtml+xml", "application/x-plist",
                     "image/svg+xml"] {
            map[mime] = .text
        }
        for mime in ["application/mbox", "application/vnd.ms-outlook", "application/vnd.ms-outlook-pst"] {
            map[mime] = .email
        }
        for mime in ["application/x-dfont"] {
            map[mime] = .font
        }
        for mime in ["application/x-apple-application", "application/x-msdownload", "application/x-mach-binary",
                     "application/x-sharedlib", "application/vnd.android.package-archive",
                     "application/x-executable"] {
            map[mime] = .application
        }
        return map
    }()

    public static func mime(forExtension ext: String) -> String? {
        byExtension[ext.lowercased()]
    }

    /// Guesses the media type from the first bytes of a file, like libmagic does in sist2.
    /// Returns nil when nothing matches and the bytes do not look like text.
    public static func sniff(_ header: Data) -> String? {
        let b = [UInt8](header.prefix(512))
        func starts(_ sig: [UInt8], at offset: Int = 0) -> Bool {
            guard b.count >= offset + sig.count else { return false }
            return Array(b[offset..<offset + sig.count]) == sig
        }
        func startsASCII(_ s: String, at offset: Int = 0) -> Bool { starts(Array(s.utf8), at: offset) }

        if b.isEmpty { return nil }
        if startsASCII("%PDF-") { return "application/pdf" }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if startsASCII("GIF87a") || startsASCII("GIF89a") { return "image/gif" }
        if startsASCII("BM") && b.count > 14 && b[6] == 0 && b[7] == 0 { return "image/bmp" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        if startsASCII("RIFF") && startsASCII("WEBP", at: 8) { return "image/webp" }
        if startsASCII("RIFF") && startsASCII("WAVE", at: 8) { return "audio/wav" }
        if startsASCII("RIFF") && startsASCII("AVI ", at: 8) { return "video/x-msvideo" }
        if startsASCII("ftyp", at: 4) {
            let brand = b.count >= 12 ? String(decoding: b[8..<12], as: UTF8.self) : ""
            switch brand {
            case "heic", "heix", "hevc", "heim", "heis", "mif1", "msf1": return "image/heic"
            case "avif", "avis": return "image/avif"
            case "qt  ": return "video/quicktime"
            case "M4A ", "M4B ": return "audio/mp4"
            case "crx ": return "image/x-canon-cr3"
            default: return "video/mp4"
            }
        }
        if startsASCII("ID3") || starts([0xFF, 0xFB]) || starts([0xFF, 0xF3]) { return "audio/mpeg" }
        if startsASCII("fLaC") { return "audio/flac" }
        if startsASCII("OggS") { return "audio/ogg" }
        if starts([0x1A, 0x45, 0xDF, 0xA3]) { return "video/x-matroska" }
        if startsASCII("PK\u{03}\u{04}") || startsASCII("PK\u{05}\u{06}") { return "application/zip" }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return "application/x-7z-compressed" }
        if startsASCII("Rar!") { return "application/vnd.rar" }
        if starts([0x1F, 0x8B]) { return "application/gzip" }
        if startsASCII("BZh") { return "application/x-bzip2" }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return "application/x-xz" }
        if starts([0x28, 0xB5, 0x2F, 0xFD]) { return "application/zstd" }
        if startsASCII("ustar", at: 257) { return "application/x-tar" }
        if starts([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return "application/x-ole-storage" }
        if startsASCII("wOFF") { return "font/woff" }
        if startsASCII("wOF2") { return "font/woff2" }
        if startsASCII("OTTO") { return "font/otf" }
        if starts([0x00, 0x01, 0x00, 0x00, 0x00]) { return "font/ttf" }
        if startsASCII("bplist") { return "application/x-plist" }
        if starts([0xCF, 0xFA, 0xED, 0xFE]) || starts([0xCA, 0xFE, 0xBA, 0xBE]) { return "application/x-mach-binary" }
        if starts([0x7F, 0x45, 0x4C, 0x46]) { return "application/x-executable" }
        if startsASCII("MZ") { return "application/x-msdownload" }
        if startsASCII("{\\rtf") { return "text/rtf" }

        guard looksLikeText(b) else { return nil }

        let head = String(decoding: b.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { return "text/html" }
        if head.hasPrefix("<?xml") {
            return head.contains("<svg") ? "image/svg+xml" : "text/xml"
        }
        if head.hasPrefix("from ") { return "application/mbox" }
        if head.hasPrefix("{") || head.hasPrefix("[") { return "application/json" }
        return "text/plain"
    }

    /// No NUL bytes and few control characters. UTF-16 text starts with a BOM and is let through.
    static func looksLikeText(_ bytes: [UInt8]) -> Bool {
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) { return true }
        var control = 0
        for byte in bytes {
            if byte == 0 { return false }
            if byte < 0x09 || (byte > 0x0D && byte < 0x20 && byte != 0x1B) { control += 1 }
        }
        return control * 20 < max(bytes.count, 1)
    }
}

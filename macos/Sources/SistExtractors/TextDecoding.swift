import Foundation

/// Decodes text files of unknown encoding: BOMs, then UTF-8, then (on macOS) Foundation's
/// detector, which knows GB18030, Big5, Shift-JIS, EUC-KR and the Windows code pages.
public enum TextDecoding {
    public static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: bytes.dropFirst(3), as: UTF8.self)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(data: Data(bytes.dropFirst(2)), encoding: .utf16LittleEndian) ?? ""
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: Data(bytes.dropFirst(2)), encoding: .utf16BigEndian) ?? ""
        }
        if let utf8 = validUTF8Prefix(bytes) {
            return utf8
        }

        #if canImport(Darwin)
        var converted: NSString?
        var lossy: ObjCBool = false
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [
                    String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))).rawValue,
                    String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.big5.rawValue))).rawValue,
                    String.Encoding.shiftJIS.rawValue,
                    String.Encoding.windowsCP1252.rawValue,
                ],
                .allowLossyKey: true,
            ],
            convertedString: &converted,
            usedLossyConversion: &lossy)
        if encoding != 0, let converted {
            return converted as String
        }
        #endif

        if let chinese = String(data: data, encoding: .gb18030) {
            return chinese
        }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Names stored as bytes in no declared encoding (zip without its UTF-8 flag, old tar): UTF-8
    /// when valid, else GB18030, which is what Windows writes in Chinese locales, else Latin-1.
    /// Shift-JIS or Big5 names come out wrong; the Chinese guess is the one this app makes.
    public static func decodeName(_ bytes: [UInt8]) -> String {
        if isValidUTF8(bytes[...]) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(bytes: bytes, encoding: .gb18030)
            ?? String(bytes: bytes, encoding: .isoLatin1)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Text in a Windows code page, as OLE property sets store it.
    public static func decode(_ bytes: [UInt8], codepage: Int) -> String {
        let encoding: String.Encoding? = switch codepage {
        case 65001: .utf8
        case 1200: .utf16LittleEndian
        case 1201: .utf16BigEndian
        case 936, 20936, 54936: .gb18030
        case 950: .big5
        case 932: .shiftJIS
        case 949: .windowsKorean
        case 1250: .windowsCP1250
        case 1251: .windowsCP1251
        case 1252: .windowsCP1252
        case 1253: .windowsCP1253
        case 1254: .windowsCP1254
        case 10000: .macOSRoman
        case 28591: .isoLatin1
        default: nil
        }
        if let encoding, let string = String(bytes: bytes, encoding: encoding) {
            return string
        }
        return decodeName(bytes)
    }

    /// The bytes as UTF-8 if they are valid UTF-8, allowing a sequence cut at the very end (the
    /// data is often a prefix of the file).
    static func validUTF8Prefix(_ bytes: [UInt8]) -> String? {
        for trim in 0...min(3, bytes.count) {
            let slice = bytes[..<(bytes.count - trim)]
            if isValidUTF8(slice) {
                return String(decoding: slice, as: UTF8.self)
            }
        }
        return nil
    }

    // String(validating:as:) would do, but needs macOS 15
    static func isValidUTF8(_ bytes: ArraySlice<UInt8>) -> Bool {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }
}

extension String.Encoding {
    // CFStringConvertEncodingToNSStringEncoding values, which Foundation also knows on Linux
    static let gb18030 = String.Encoding(rawValue: 0x8000_0632)
    static let big5 = String.Encoding(rawValue: 0x8000_0A03)
    static let windowsKorean = String.Encoding(rawValue: 0x8000_0422)
}

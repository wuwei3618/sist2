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

        return String(data: data, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
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

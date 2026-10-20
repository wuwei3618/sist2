import Foundation
import Testing
import SistCore
@testable import SistExtractors

/// outlook.msg and archive.pst are written by Fixtures/outlook.py and checked with extract-msg,
/// libpst and libpff (see generate.py)
@Suite struct OutlookTests {
    /// Documents by path, the last version of each: a member with members of its own is emitted
    /// twice, before them and complete
    func documents(_ results: [ParseResult]) -> [String: ParsedDocument] {
        Dictionary(results.map { ($0.document.path, $0.document) }, uniquingKeysWith: { _, last in last })
    }

    @Test func message() throws {
        let path = Fixture.url("outlook.msg").path
        let all = documents(try parseFile("outlook.msg"))
        let message = try #require(all[path])
        #expect(message.category == .email)
        #expect(message.error == nil)
        #expect(message.title == "周报：项目进度")
        #expect(message.metadata[MetaKey.emailFrom] == .string("王五 <wangwu@example.com>"))
        #expect(message.metadata[MetaKey.emailTo] == .string("李四; 赵六"))
        #expect(message.metadata[MetaKey.emailDate] == .string("2024-03-05T06:30:00Z"))
        #expect(message.content?.contains("本周完成了索引模块。msg body walrus") == true)
        #expect(all[path + "#/会议纪要.txt"]?.content == "附件文字 msg attachment walrus")
        #expect(all[path + "#/big.bin"]?.size == 5120)
    }

    @Test func dataFile() throws {
        let path = Fixture.url("archive.pst").path
        let all = documents(try parseFile("archive.pst"))
        let file = try #require(all[path])
        #expect(file.category == .email)
        #expect(file.error == nil)
        #expect(file.title == "个人文件夹")
        #expect(file.metadata[MetaKey.archiveMembers] == .int(4))

        let messages = all.values.filter { $0.parentPath == path }.map(\.path).sorted()
        #expect(messages == ["收件箱/00001 季度报告：华东地区.eml", "收件箱/00002 长邮件.eml", "收件箱/项目/00001 转发：项目计划.eml",
                             "已删除邮件/00001 deleted penguins.eml"].map { path + "#/" + $0 }.sorted())

        let first = try #require(all[path + "#/收件箱/00001 季度报告：华东地区.eml"])
        #expect(first.title == "季度报告：华东地区")
        #expect(first.metadata[MetaKey.emailFrom] == .string("张三 <zhangsan@example.com>"))
        #expect(first.metadata[MetaKey.emailTo] == .string("李四"))
        #expect(first.metadata[MetaKey.emailCc] == .string("赵六"))
        #expect(first.content?.contains("附件是华东地区的季度销售数据。pst body walrus") == true)
        #expect(all[first.path + "#/销售数据.txt"]?.content == "附件里的文字 pst attachment walrus")
        #expect(all[first.path + "#/大附件.bin"]?.size == 20000)

        // A body spread over several blocks
        #expect(all[path + "#/收件箱/00002 长邮件.eml"]?.content?.contains("长文本长文本 long body end marker") == true)

        // An attached message, with an attachment of its own
        let forwarded = path + "#/收件箱/项目/00001 转发：项目计划.eml#/原始邮件.eml"
        #expect(all[forwarded]?.title == "原始邮件")
        #expect(all[forwarded]?.content?.contains("被转发的原始邮件正文 embedded walrus") == true)
        #expect(all[forwarded + "#/计划.txt"]?.content == "嵌套附件 nested walrus")
    }

    @Test func ansiDataFile() throws {
        let path = Fixture.url("ansi.pst").path
        let all = documents(try parseFile("ansi.pst"))
        #expect(all[path]?.error == nil)
        // The folder name has no code page: GB18030 is guessed
        let first = try #require(all[path + "#/收件箱/00001 旧格式邮件.eml"])
        #expect(first.metadata[MetaKey.emailFrom] == .string("张三"))
        #expect(first.content?.contains("ANSI 格式的正文 ansi walrus") == true)
        #expect(all[first.path + "#/附件.txt"]?.content == "ansi attachment")
        // The message says it is in Windows-1252
        #expect(all[path + "#/收件箱/00002 café.eml"]?.content?.contains("latin body café") == true)
    }

    @Test func membersCanBeReadBackOut() throws {
        let pst = Fixture.url("archive.pst").path
        let big = try ArchiveMemberReader.data(forPath: pst + "#/收件箱/00001 季度报告：华东地区.eml#/大附件.bin")
        #expect(big == Data((0..<20000).map { UInt8($0 * 7 % 251) }))
        let nested = try ArchiveMemberReader.data(
            forPath: pst + "#/收件箱/项目/00001 转发：项目计划.eml#/原始邮件.eml#/计划.txt")
        #expect(nested == Data("嵌套附件 nested walrus".utf8))
        #expect(throws: ExtractionError.self) { try ArchiveMemberReader.data(forPath: pst + "#/收件箱/00009 missing.eml") }

        let msg = Fixture.url("outlook.msg").path
        #expect(try ArchiveMemberReader.data(forPath: msg + "#/会议纪要.txt") == Data("附件文字 msg attachment walrus".utf8))
    }

    @Test func listModeOnlyNamesMessages() throws {
        var options = Fixture.options()
        options.archiveMode = .list
        let results = try parseFile("archive.pst", options: options)
        #expect(results.count == 1)
        #expect(results[0].document.content?.contains("deleted penguins") == true)
    }

    @Test func recognizedWithoutExtension() throws {
        #expect(MimeTypes.sniff(try Data(contentsOf: Fixture.url("archive.pst"))) == "application/vnd.ms-outlook-pst")
        // A .msg without its extension is a compound file; the Office parser hands it over
        let data = try Data(contentsOf: Fixture.url("outlook.msg"))
        let documents = parseBytes(data, name: "message")
        #expect(documents.last?.title == "周报：项目进度")
    }

    @Test func compressedRTF() throws {
        // Compressed by the compressed_rtf Python package
        let compressed = Array(hex: "9e000000c60000004c5a4675b0e12d5f03000a00726370673933364f00f401f702a7020063680ac07360657431333406000770535c756e0280029108e63b096f304902805c760890776b0b80643a340c606300500b030bb520484c656c09000330276313b0272465331540626115413320fa7705b06c0b310ac1103005a0139054206c0b806503307501d0300510603f17b1353939313f5420640220650aa27d1950")
        let rtf = try #require(CompressedRTF.decompress(compressed))
        #expect(rtf.count == 198)
        #expect(String(decoding: rtf, as: UTF8.self).hasPrefix("{\\rtf1\\ansi\\ansicpg936"))
        // GBK bytes in \'hh, characters in \uN with a fallback to skip
        #expect(RTFText.plainText(rtf) == "Hello 你好 world\nsecond line 中文 done")

        let raw = Array("{\\rtf1 plain}".utf8)
        let mela = [UInt8](repeating: 0, count: 4) + [UInt8(raw.count), 0, 0, 0] + Array("MELA".utf8) + [0, 0, 0, 0] + raw
        #expect(CompressedRTF.decompress(mela) == raw)
        #expect(CompressedRTF.decompress([1, 2, 3]) == nil)
    }

    @Test func rtfDestinationsAreSkipped() {
        let rtf = "{\\rtf1{\\fonttbl{\\f0 Arial;}}{\\*\\generator Writer;}{\\info{\\title T}}Body \\{braces\\} \\\\ end\\par next\\tab col}"
        #expect(RTFText.plainText(Array(rtf.utf8)) == "Body {braces} \\ end\nnext\tcol")
    }

    @Test func ciphers() {
        let plain: [UInt8] = Array("测试 cipher".utf8)
        var permuted = plain.map { PSTCipher.r[Int($0)] }
        PSTCipher.decrypt(&permuted, method: 1, key: 0)
        #expect(permuted == plain)
        // High encryption is its own inverse
        var cyclic = plain
        PSTCipher.decrypt(&cyclic, method: 2, key: 0x1234_ABCD)
        #expect(cyclic != plain)
        PSTCipher.decrypt(&cyclic, method: 2, key: 0x1234_ABCD)
        #expect(cyclic == plain)
    }

    @Test func damagedFilesNeverCrash() throws {
        let original = try [UInt8](Data(contentsOf: Fixture.url("archive.pst")))
        var generator = SeededGenerator(seed: 7)
        for round in 0..<150 {
            var bytes = original
            if round % 3 == 0 {
                bytes.removeSubrange(Int.random(in: 600..<bytes.count, using: &generator)...)
            } else {
                for _ in 0..<Int.random(in: 1...40, using: &generator) {
                    bytes[Int.random(in: 512..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                }
            }
            _ = parseBytes(Data(bytes), name: "damaged.pst")
        }
        let msg = try [UInt8](Data(contentsOf: Fixture.url("outlook.msg")))
        for _ in 0..<100 {
            var bytes = msg
            for _ in 0..<20 {
                bytes[Int.random(in: 512..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = parseBytes(Data(bytes), name: "damaged.msg")
        }
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

extension Array where Element == UInt8 {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index < hex.endIndex {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self = bytes
    }
}

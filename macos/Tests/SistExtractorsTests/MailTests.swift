import Foundation
import Testing
import SistCore
@testable import SistExtractors

/// Fixtures written by Python's email and mailbox modules (Fixtures/generate.py)
@Suite struct MailTests {
    func members(of path: String, in results: [ParseResult]) -> [String: ParsedDocument] {
        Dictionary(results.map(\.document).filter { $0.parentPath == path }.map { ($0.name, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    @Test(arguments: ["chinese.eml", "message.emlx"])
    func chineseMessage(_ name: String) throws {
        let results = try parseFile(name)
        let path = Fixture.url(name).path
        let message = try #require(results.last { $0.document.path == path }?.document)
        #expect(message.category == .email)
        #expect(message.error == nil)
        #expect(message.title == "季度报告：华东地区销售数据")
        #expect(message.metadata[MetaKey.emailFrom] == .string("张三 <zhangsan@example.com>"))
        #expect(message.metadata[MetaKey.emailTo] == .string("李四 <lisi@example.com>"))
        #expect(message.metadata[MetaKey.emailCc] == .string("zhaoliu@example.com"))
        #expect(message.metadata[MetaKey.emailDate] == .string("2024-03-05T06:30:00Z"))

        let content = try #require(message.content)
        #expect(content.hasPrefix("From: 张三 <zhangsan@example.com>"))
        #expect(content.contains("华东地区的季度销售数据"))
        // Of the two alternatives, the plain one
        #expect(content.contains("plain body marker"))
        #expect(!content.contains("html-only marker"))
        #expect(content.contains("Attachments: 销售数据.txt, data.bin, 转发：项目计划.eml"))

        let attachments = members(of: path, in: results)
        #expect(Set(attachments.keys) == ["销售数据.txt", "data.bin", "转发：项目计划.eml"])
        #expect(attachments["销售数据.txt"]?.content == "附件里的文字 attachment walrus")
        #expect(attachments["销售数据.txt"]?.mtime == 1_709_620_200)
        let forwarded = try #require(attachments["转发：项目计划.eml"])
        #expect(forwarded.title == "转发：项目计划")
        #expect(forwarded.content?.contains("被转发的邮件正文 forwarded walrus") == true)
    }

    @Test func mailbox() throws {
        let results = try parseFile("inbox.mbox")
        let path = Fixture.url("inbox.mbox").path
        let mailbox = try #require(results.last { $0.document.path == path }?.document)
        #expect(mailbox.category == .email)
        #expect(mailbox.metadata[MetaKey.archiveMembers] == .int(3))
        #expect(mailbox.content == "第一封：会议通知\n季度报告：华东地区销售数据\nThird / with a slash")

        // A member with members of its own is emitted twice, before them and complete
        var messages: [ParsedDocument] = []
        for document in results.map(\.document) where document.parentPath == path {
            if let index = messages.firstIndex(where: { $0.path == document.path }) {
                messages[index] = document
            } else {
                messages.append(document)
            }
        }
        #expect(messages.map(\.name) == ["00001 第一封：会议通知.eml", "00002 季度报告：华东地区销售数据.eml",
                                         "00003 Third _ with a slash.eml"])
        // ">From " in a body is the escaped "From "
        let first = try #require(messages.first?.content)
        #expect(first.contains("第一封邮件\nFrom the start of a line"))
        #expect(messages.first?.mtime == 1_709_542_800)
        // The attachments of a message are its members
        #expect(members(of: messages[1].path, in: results)["销售数据.txt"]?.content == "附件里的文字 attachment walrus")
        #expect(messages[2].content?.contains("penguins") == true)
    }

    @Test func membersCanBeReadBackOut() throws {
        let eml = Fixture.url("chinese.eml").path
        #expect(try ArchiveMemberReader.data(forPath: eml + "#/销售数据.txt") == Data("附件里的文字 attachment walrus".utf8))
        let forwarded = try ArchiveMemberReader.data(forPath: eml + "#/转发：项目计划.eml")
        #expect(MIMEPart([UInt8](forwarded)[...]).header("subject") == "转发：项目计划")

        let mbox = Fixture.url("inbox.mbox").path
        let third = try ArchiveMemberReader.data(forPath: mbox + "#/00003 Third _ with a slash.eml")
        #expect(String(decoding: third, as: UTF8.self).contains("penguins"))
        // An attachment of a message of a mailbox
        let nested = try ArchiveMemberReader.data(forPath: mbox + "#/00002 季度报告：华东地区销售数据.eml#/销售数据.txt")
        #expect(nested == Data("附件里的文字 attachment walrus".utf8))
        #expect(throws: ExtractionError.self) { try ArchiveMemberReader.data(forPath: mbox + "#/missing.eml") }
    }

    @Test func listModeOnlyNamesAttachments() throws {
        var options = Fixture.options()
        options.archiveMode = .list
        let results = try parseFile("chinese.eml", options: options)
        #expect(results.count == 1)
        #expect(results[0].document.content?.contains("Attachments: 销售数据.txt") == true)

        let mailbox = try parseFile("inbox.mbox", options: options)
        #expect(mailbox.count == 1)
        #expect(mailbox[0].document.content?.contains("Third / with a slash") == true)
    }

    @Test func recognizedWithoutExtension() throws {
        let data = try Data(contentsOf: Fixture.url("chinese.eml"))
        // Python writes Content-Type first; mail software usually starts with Received or Return-Path
        let received = Data("Received: from mx.example.com\r\n".utf8) + data
        #expect(MimeTypes.sniff(received) == "message/rfc822")
        #expect(MimeTypes.sniff(try Data(contentsOf: Fixture.url("inbox.mbox"))) == "application/mbox")
    }

    @Test func encodedWords() {
        // The bytes of one character split over two words are decoded together
        #expect(HeaderText.decodeWords("=?UTF-8?B?5Lg=?= =?UTF-8?B?reaWhw==?=") == "中文")
        #expect(HeaderText.decodeWords("Re: =?gb2312?B?1tDOxA==?= report") == "Re: 中文 report")
        #expect(HeaderText.decodeWords("=?iso-8859-1?Q?caf=E9_cr=E8me?=") == "café crème")
        #expect(HeaderText.decodeWords("=?utf-8*zh?b?5Lit5paH?=") == "中文")
        #expect(HeaderText.decodeWords("plain =?broken") == "plain =?broken")
        // 8-bit headers from mailers that do not encode: UTF-8, else GB18030
        #expect(HeaderText.decode(Array("主题".utf8)) == "主题")
        #expect(HeaderText.decode([0xD6, 0xD0, 0xCE, 0xC4]) == "中文")
    }

    @Test func parameters() {
        let simple = HeaderText.parameters("attachment; filename*=utf-8''%E9%94%80%E5%94%AE.txt")
        #expect(simple.value == "attachment")
        #expect(simple.parameters["filename"] == "销售.txt")

        let continued = HeaderText.parameters("attachment; filename*0*=utf-8''%E4%B8%AD; filename*1*=%E6%96%87; filename*2=.pdf")
        #expect(continued.parameters["filename"] == "中文.pdf")

        let quoted = HeaderText.parameters("Text/Plain; name=\"a;b.txt\"; CHARSET=GBK")
        #expect(quoted.value == "text/plain")
        #expect(quoted.parameters["name"] == "a;b.txt")
        #expect(quoted.parameters["charset"] == "GBK")

        // Outlook and Chinese webmail put encoded words in quoted names
        #expect(HeaderText.parameters("application/pdf; name=\"=?GB2312?B?1tDOxA==?=.pdf\"").parameters["name"] == "中文.pdf")
    }

    @Test func dates() {
        #expect(MailDate.parse("Tue, 05 Mar 2024 14:30:00 +0800") == Date(timeIntervalSince1970: 1_709_620_200))
        #expect(MailDate.parse("5 Mar 2024 06:30 GMT") == Date(timeIntervalSince1970: 1_709_620_200))
        #expect(MailDate.parse("Tue, 5 Mar 24 14:30:00 -0500 (EST)") == Date(timeIntervalSince1970: 1_709_667_000))
        #expect(MailDate.parse("Mon Mar  4 09:00:00 2024") == Date(timeIntervalSince1970: 1_709_542_800))
        #expect(MailDate.parse("yesterday") == nil)
        #expect(MailDate.parse("") == nil)
    }

    @Test func transferEncodings() {
        #expect(QuotedPrintable.decode(Array("caf=C3=A9 =\r\nsoft=  \nbreak =ZZ".utf8)[...]) == Array("café softbreak =ZZ".utf8))
        #expect(Base64.decode(Array("5Lit\r\n5paH".utf8)) == Array("中文".utf8))
        #expect(Base64.decode(Array("!!!".utf8)).isEmpty)
    }

    @Test func messagesWithoutHeadersOrBody() {
        let bodyOnly = MIMEPart(Array("just some text\nand more".utf8)[...])
        #expect(bodyOnly.headers.isEmpty)
        #expect(String(decoding: bodyOnly.body, as: UTF8.self) == "just some text\nand more")

        let headersOnly = MIMEPart(Array("Subject: hello\r\nX-Folded: one\r\n two".utf8)[...])
        #expect(headersOnly.header("subject") == "hello")
        #expect(headersOnly.header("x-folded") == "one two")
        #expect(headersOnly.body.isEmpty)

        // A multipart body that never closes still yields its parts
        let open = MIMEPart(Array("Content-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: text/plain\n\nfirst\n--b\n\nsecond".utf8)[...])
        var body = MailBody()
        body.collect(open, depth: 0)
        #expect(body.texts == ["first", "second"])
    }
}
